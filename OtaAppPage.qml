import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import QtCore
import PdM.Core

/*
 * The OTA updater, as a page: navigation, the shared models, and the MQTT
 * wiring. The five screens live in their own files.
 *
 * A Page and not an ApplicationWindow, because in Maestro this lives inside a
 * tab and a tab cannot contain a window. Page was the right shape to land on:
 * it is an Item, so it drops into the tab stack, and it keeps `header`, which
 * the ToolBar below needs and a plain Item does not have. The window that used
 * to be here is now Main.qml, which exists only for the standalone build.
 *
 * `id: app` is kept -- fifteen bindings refer to it, all of them naming
 * properties declared here rather than window API.
 *
 * MqttClient and Control need no import: they are registered into this file's
 * own module, PdM.Ota, by QML_ELEMENT in their headers.
 */
Page {
    id: app

    /* Page has no `color`; the equivalent is a background item. It also makes
       the page opaque wherever it is placed, rather than inheriting whatever is
       behind it in the tab stack. */
    background: Rectangle { color: Theme.background }

    Material.theme: Theme.dark ? Material.Dark : Material.Light
    Material.primary: Theme.primary
    Material.accent: Theme.primary
    Material.foreground: Theme.textPrimary
    /* Deliberately NOT Material.background: the attached property propagates to
       every control below, and Material's Button paints that inherited surface
       colour in place of its accent. See FilledButton.qml. */

    /* ======================== shared state ======================== */

    ListModel { id: guestsModel }        /* id, name, type, state, pid, ip, running */
    ListModel { id: partitionsModel }    /* name, kind, exists, size */
    ListModel { id: stagedModel }        /* destName, local, serverPath, sent, downloaded, state */
    ListModel { id: sendModel }          /* local, dest */
    ListModel { id: browseModel }        /* name, isDir, size */

    /* Where the local file picker and the guest filesystem browser last
       left off, persisted across app restarts (not just within a run) --
       both used to always reopen at their starting point (home directory,
       guest root) no matter where the last pick happened, which meant
       re-selecting a file or destination deep in a tree every single time. */
    Settings {
        id: uiSettings
        category: "browse"
        property string lastLocalFolder: ""
        property string lastGuestPath: "/"
    }

    /* Named sets of (local file, guest destination) pairs for the "Send
       files" list, persisted across restarts the same way as uiSettings
       above. Settings only stores plain values, not arrays of objects, so
       the whole preset map is kept as one JSON string and (de)serialized on
       each save/load rather than as a second, separately-synced copy that
       could drift from what is actually on disk. */
    Settings {
        id: presetSettings
        category: "sendPresets"
        property string presetsJson: "{}"
    }

    function loadSendPresets() {
        try {
            var obj = JSON.parse(presetSettings.presetsJson);
            return obj && typeof obj === "object" ? obj : {};
        } catch (e) {
            return {};
        }
    }

    function sendPresetNames() {
        var names = Object.keys(loadSendPresets());
        names.sort();
        return names;
    }

    /* Saves the CURRENT sendModel (local paths and their guest destinations)
       under `name`, overwriting any preset already saved under it. Only the
       paths are kept, not the files themselves -- if a local file has since
       moved or been deleted, loading the preset back will queue a path that
       no longer resolves, the same as re-typing a stale path by hand would. */
    function saveSendPreset(name) {
        name = name.trim();
        if (name === "" || sendModel.count === 0) return;
        var presets = loadSendPresets();
        var entries = [];
        for (var i = 0; i < sendModel.count; ++i) {
            var r = sendModel.get(i);
            entries.push({ local: r.local, dest: r.dest });
        }
        presets[name] = entries;
        presetSettings.presetsJson = JSON.stringify(presets);
        log("info", "Saved " + entries.length + " file(s) as \"" + name + "\".");
    }

    /* Replaces sendModel's current contents with the saved preset's. */
    function loadSendPreset(name) {
        var presets = loadSendPresets();
        var entries = presets[name];
        if (!entries) return;
        sendModel.clear();
        for (var i = 0; i < entries.length; ++i)
            sendModel.append({ local: entries[i].local, dest: entries[i].dest });
        log("info", "Loaded " + entries.length + " file(s) from \"" + name + "\".");
    }

    function deleteSendPreset(name) {
        var presets = loadSendPresets();
        delete presets[name];
        presetSettings.presetsJson = JSON.stringify(presets);
    }

    property int    currentPage: 0
    property bool   guestsLoading: false
    property string lastUpdateText: ""

    property int    guestIndex: 0
    readonly property string selectedGuestId:
        (guestIndex >= 0 && guestIndex < guestsModel.count)
            ? guestsModel.get(guestIndex).id : ""

    property bool otaDeploying: false
    property bool uploadingNow: false
    property bool pushingNow: false
    readonly property bool otaBusy: otaDeploying || uploadingNow || pushingNow
    /* otaBusy is the shared button-lock -- it deliberately includes
       pushingNow too, so Replace/Apply/Send-to-guest can't run concurrently
       with each other. The Replace -> Apply progress bar and its stepper
       must NOT use it for their own busy/colour state though: doing so made
       that bar animate (and its "N%" label appear) for a Send-to-guest push
       that never touches progressPercent at all, since otaBusy alone was
       already true. This is the partition-flow-only equivalent. */
    readonly property bool partitionBusy: otaDeploying || uploadingNow

    property string currentGuestType: ""
    property bool   chkUploaded: false
    property bool   chkDownloaded: false
    property bool   chkApplied: false
    property string otaStage: ""
    property real   progressPercent: 0
    property string uploadFileName: ""
    property string downloadFileName: ""
    property string otaPhase: ""
    property int    currentStageIdx: -1
    property string otaStageLabel: "Select a guest, then choose replacement files for its partitions."
    property string pushStatus: ""
    /* Send to guest gets its own three-step tracker and its own progress bar
       -- entirely separate from chkUploaded/chkDownloaded/chkApplied and
       progressPercent above, which are Replace -> Apply's. Reusing those
       previously enabled the "Apply and restart guest" button and lit that
       flow's step 3 after a plain push, which has nothing to apply. */
    property bool   pushUploaded: false    /* archive reached the server */
    property bool   pushPulled: false      /* host pulled it down from the server */
    property bool   pushDelivered: false   /* extracted into the running guest */
    property real   pushProgressPercent: 0

    property string infoGuestId: ""
    property var    infoFields: []

    property string pickerDest: ""
    property int    browseRow: -1
    property string browsePath: "/"
    property string browseSelected: ""
    property bool   lsPending: false
    /* Persist wherever the guest browser last navigated to, the same as the
       local file picker (uiSettings.lastLocalFolder) -- it used to always
       reopen at the guest's root regardless of where a previous browse had
       gone. */
    onBrowsePathChanged: uiSettings.lastGuestPath = browsePath

    function log(type, text) { logPanel.append(type, text) }

    function selectGuestByIndex(i) {
        if (i < 0 || i >= guestsModel.count) return;
        guestIndex = i;
        refreshPartitions();
    }

    function fmtSize(bytes) {
        if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(2) + " GB";
        if (bytes >= 1048576)    return (bytes / 1048576).toFixed(1) + " MB";
        if (bytes >= 1024)       return (bytes / 1024).toFixed(1) + " KB";
        if (bytes > 0)           return bytes + " B";
        return "—";
    }

    function joinGuestPath(base, name) {
        if (base === "/") return "/" + name;
        if (base.endsWith("/")) return base + name;
        return base + "/" + name;
    }

    function openShellFor(id) {
        shellPage.setGuest(id);
        currentPage = 2;
    }

    /* ---------------- partitions / staging ---------------- */

    function refreshPartitions() {
        if (selectedGuestId !== "") mqtt.guestFiles(selectedGuestId);
    }

    function loadPartitions(json) {
        partitionsModel.clear();
        stagedModel.clear();
        chkUploaded = false; chkDownloaded = false; chkApplied = false;
        otaStage = ""; otaPhase = ""; currentStageIdx = -1; progressPercent = 0;
        try {
            var obj = JSON.parse(json);
            currentGuestType = obj.type || "";
            for (var i = 0; i < obj.files.length; ++i) {
                var f = obj.files[i];
                partitionsModel.append({
                    name: f.name, kind: f.kind, exists: f.exists, size: f.size
                });
            }
        } catch (e) {
            log("error", "Could not parse the partition list: " + e.message);
        }
    }

    function stagePartition(destName, localPath) {
        chkUploaded = false; chkDownloaded = false; chkApplied = false;
        var row = { destName: destName, local: localPath, serverPath: "",
                    sent: false, downloaded: false, state: "" };
        for (var i = 0; i < stagedModel.count; ++i) {
            if (stagedModel.get(i).destName === destName) {
                stagedModel.set(i, row);
                return;
            }
        }
        stagedModel.append(row);
    }

    function sentCount() {
        var n = 0;
        for (var i = 0; i < stagedModel.count; ++i)
            if (stagedModel.get(i).sent) n++;
        return n;
    }

    function readyCount() {
        var n = 0;
        for (var i = 0; i < stagedModel.count; ++i)
            if (stagedModel.get(i).downloaded) n++;
        return n;
    }

    function setRowState(i, state) {
        var r = stagedModel.get(i);
        stagedModel.set(i, {
            destName: r.destName, local: r.local, serverPath: r.serverPath,
            sent: r.sent, downloaded: r.downloaded, state: state
        });
    }

    function sendAll() {
        if (uploadingNow) return;
        uploadingNow = true;
        chkUploaded = false; chkDownloaded = false; chkApplied = false; otaStage = "";
        otaPhase = "upload";
        for (var i = 0; i < stagedModel.count; ++i) {
            var r = stagedModel.get(i);
            if (!r.downloaded)
                stagedModel.set(i, {
                    destName: r.destName, local: r.local,
                    serverPath: r.sent ? r.serverPath : "",
                    sent: r.sent, downloaded: false, state: ""
                });
        }
        uploadNext();
    }

    function uploadNext() {
        var idx = -1;
        for (var i = 0; i < stagedModel.count; ++i)
            if (!stagedModel.get(i).sent) { idx = i; break; }
        if (idx < 0) {
            uploadingNow = false;
            doFetch();
            return;
        }
        currentStageIdx = idx;
        setRowState(idx, "uploading");
        var row = stagedModel.get(idx);
        log("info", "Uploading " + row.local + " → " + row.destName);
        otaStageLabel = "Uploading " + row.destName + " to the server…";
        mqtt.uploadOtaFile(row.local, row.destName);
    }

    function doFetch() {
        /* Every file not yet downloaded, sent in ONE fetchOtaFiles() call --
           not one call per file. hms/ota/ota.c's ota_fetch_thread() clears
           and recreates the guest's whole stage/ directory once at the start
           of EACH job it runs, on the assumption that a job's n_paths is the
           complete list wanted this round. That is exactly right for a
           single batched call; called once per file instead, each file's own
           job wiped out whatever the previous call had just pulled down, so
           only the last file fetched ever survived to the stage directory.
           fetchOtaFiles() already accepts the whole list (it joins them into
           one "fetch <guest> <path1> <path2> ..." command) -- this was
           simply never exercised with more than one path at a time. */
        var idxs = [];
        for (var i = 0; i < stagedModel.count; ++i)
            if (stagedModel.get(i).sent && !stagedModel.get(i).downloaded) idxs.push(i);
        if (idxs.length === 0) {
            if (stagedModel.count > 0 && readyCount() === stagedModel.count) {
                chkDownloaded = true;
                uploadingNow = false;
                otaDeploying = false;
                otaStageLabel = "All files are on the host — press Apply to install them.";
            }
            return;
        }
        var paths = [];
        for (var j = 0; j < idxs.length; ++j) {
            setRowState(idxs[j], "downloading");
            paths.push(stagedModel.get(idxs[j]).serverPath);
        }
        otaPhase = "fetch";
        otaDeploying = true;
        chkDownloaded = false; chkApplied = false; otaStage = "";
        mqtt.fetchOtaFiles(selectedGuestId, paths);
        otaStageLabel = "Pulling " + paths.length + " file(s) from the server down to the host…";
    }

    function doApply() {
        mqtt.applyOtaFiles(selectedGuestId, true);
        otaStageLabel = "Applying: stopping the guest, replacing files, restarting…";
        otaDeploying = true;
        otaPhase = "apply";
        chkDownloaded = false; chkApplied = false; otaStage = "";
    }

    /* ---------------- send files ---------------- */

    function allSendDestSet() {
        for (var i = 0; i < sendModel.count; ++i)
            if (sendModel.get(i).dest.trim() === "") return false;
        return true;
    }

    function sendEntriesList() {
        var a = [];
        for (var i = 0; i < sendModel.count; ++i) {
            var r = sendModel.get(i);
            a.push({ "local": r.local, "dest": r.dest });
        }
        return a;
    }

    function sendFilesToGuest() {
        if (otaBusy) return;
        if (sendModel.count === 0) { log("error", "Nothing to send — add a file first."); return; }
        if (!allSendDestSet())     { log("error", "Every file needs a destination path in the guest."); return; }
        if (selectedGuestId === "") { log("error", "Select a guest first."); return; }

        pushStatus = "Packing " + sendModel.count + " file(s)…";
        pushProgressPercent = 0;
        pushUploaded = false; pushPulled = false; pushDelivered = false;
        pushingNow = true;
        otaPhase = "push";
        var tarPath = mqtt.buildPushTar(sendEntriesList(), "/tmp/pushfiles.tar.gz");
        if (tarPath === "") {
            pushingNow = false;
            otaPhase = "";
            pushStatus = "Could not build the archive.";
            return;
        }
        pushStatus = "Uploading the archive to the server…";
        mqtt.uploadGenericFile(tarPath, "pushfiles.tar.gz");
    }

    /* ---------------- pickers ---------------- */

    function pickPartitionFile(name) {
        pickerDest = name;
        filePicker.mode = "partition";
        filePicker.open();
    }

    function pickSendFile() {
        pickerDest = "";
        filePicker.mode = "send";
        filePicker.open();
    }

    function browseGuestFor(rowIndex) {
        browseRow = rowIndex;
        guestBrowser.open();
    }

    /* ======================== MQTT ======================== */

    MqttClient {
        id: mqtt

        onGuestListReceived: (json) => {
            try {
                var obj = JSON.parse(json);
            } catch (e) {
                log("error", "Malformed guest list from HMS: " + e.message);
                guestsLoading = false;
                return;
            }
            var previousId = selectedGuestId;

            /* Updated in place rather than cleared and rebuilt.
               HMS now pushes this list whenever anything about a guest
               changes, not just when Refresh is pressed, so this runs on its
               own several times during a single boot. clear() destroys and
               recreates every delegate, which throws away the ListView's
               scroll position and flashes the whole table each time -- barely
               noticeable once, very noticeable when a guest coming up emits
               several updates in a row. set() leaves the rows alone and
               repaints only the properties that actually differ. */
            for (var i = 0; i < obj.guests.length; ++i) {
                var g = obj.guests[i];
                var row = {
                    id: g.id,
                    name: g.name || "-",
                    type: g.type,
                    state: g.state,
                    pid: g.pid,
                    ip: g.ip,
                    running: g.state === "running",
                    /* Running but not yet answering SSH — the guest is booting.
                       Older HMS builds omit the field; treat that as reachable
                       so this does not disable the shell against them. */
                    reachable: g.reachable !== false
                };
                if (i < guestsModel.count) guestsModel.set(i, row);
                else                       guestsModel.append(row);
            }
            /* Drop any trailing rows left by a guest that has gone away. */
            while (guestsModel.count > obj.guests.length)
                guestsModel.remove(guestsModel.count - 1);

            /* Keep the selection on the same guest across a refresh. It used to
               be kept by index, so a guest appearing or disappearing silently
               moved every subsequent action onto a different guest. */
            guestIndex = 0;
            for (var j = 0; j < guestsModel.count; ++j)
                if (guestsModel.get(j).id === previousId) { guestIndex = j; break; }

            guestsLoading = false;
            lastUpdateText = "Updated " + Qt.formatTime(new Date(), "hh:mm:ss");
            /* Not logged any more: this arrives on every change now, and one
               "Guest list: 2 guest(s)" per update buries everything else. */
        }

        onGuestInfoReceived: (json) => {
            try {
                var obj = JSON.parse(json);
            } catch (e) {
                log("error", "Malformed guest info: " + e.message);
                return;
            }
            infoGuestId = obj.guest.id;
            infoFields = [
                { key: "ID",        value: obj.guest.id },
                { key: "Hostname",  value: obj.guest.name || "—" },
                { key: "Type",      value: obj.guest.type },
                { key: "State",     value: obj.guest.state },
                { key: "PID",       value: String(obj.guest.pid) },
                { key: "Address",   value: obj.guest.ip },
                { key: "Config",    value: obj.guest.conf },
                { key: "Boot image",value: obj.guest.boot },
                { key: "RootFS",    value: obj.guest.rootfs },
                { key: "SSH user",  value: obj.guest.ssh_user },
                { key: "SSH port",  value: String(obj.guest.ssh_port) },
                { key: "SSH key",   value: obj.guest.ssh_key }
            ];
            infoDialog.open();
        }

        onCmdResult: (cmd, guest, success, msg) => {
            if (cmd === "start" || cmd === "kill")
                mqtt.refreshGuests();
        }

        onExecOutput: (guest, output) => {
            /* The browser borrows exec to list a directory. It used to swallow
               every exec reply whenever the dialog happened to be open, so the
               shell went silent while browsing. */
            if (guestBrowser.opened && lsPending) guestBrowser.parseListing(output);
            else shellPage.onExecOutput(guest, output);
        }

        onShellOpened: (guest, msg) => shellPage.onShellOpened(guest, msg)
        onShellOutput: (guest, data) => shellPage.onShellOutput(guest, data)
        onShellClosed: (guest, msg) => shellPage.onShellClosed(guest, msg)

        onAddGuestResult: (guest, success, msg) => { if (success) mqtt.refreshGuests() }
        onAddFileResult:  (guest, success, msg) => { if (success) refreshPartitions() }

        onGuestStatsReceived: (json) => monitorPage.onStats(json)

        /* A reply outstanding when the link dropped is never coming -- the
           session it was addressed to is gone. Tell the Monitor so it stops
           waiting on it; otherwise it sits out its 60s watchdog while the
           client has already reconnected. */
        onConnectedChanged: monitorPage.onLinkChanged(mqtt.connected)
        onGuestFilesReceived: (json) => loadPartitions(json)

        onUploadProgress: (percent, fileName) => {
            /* uploadOtaFile() (Replace's own upload) and uploadGenericFile()
               (Send to guest's tar upload) are two different Q_INVOKABLEs in
               mqttclient.cpp, but both report through this ONE uploadProgress
               signal -- there is nothing in the signal itself to say which
               kind of upload it is. Without this check, a push's archive
               upload wrote straight into progressPercent/otaStageLabel,
               which the top (partition) bar reads, printing that flow's
               file/percent up there even though nothing partition-related
               was happening. pushingNow is only ever true for the span of a
               Send-to-guest push (see sendFilesToGuest()), and the two flows
               are mutually exclusive (both gated on otaBusy), so it reliably
               tells the two apart. */
            if (pushingNow) {
                pushProgressPercent = percent;
                pushStatus = "Uploading " + fileName + " to the server — " + percent + "%";
                return;
            }
            progressPercent = percent;
            otaStage = "upload";
            uploadFileName = fileName;
            otaStageLabel = "Uploading " + fileName + " to the server — " + percent + "%";
        }

        onOtaProgress: (guest, stage, progress, msg) => {
            /* Send to guest has its own progress bar and three-step tracker
               (pushUploaded/pushPulled/pushDelivered below) -- entirely
               separate from the Replace -> Apply flow's progressPercent/
               otaStageLabel/otaDeploying, which this must not touch. */
            if (stage === "pushfiles") {
                pushProgressPercent = progress;
                pushStatus = msg;
                /* ota_push_thread() (hms/ota/ota.c) reports exactly this text
                   the moment the pull from the server finishes and it starts
                   scp'ing the archive into the guest -- the one checkpoint
                   that marks "2. Pull to host" done and "3. Send to guest"
                   starting. */
                if (msg.indexOf("Archive pulled") >= 0) pushPulled = true;
                return;
            }
            otaStageLabel = msg;
            progressPercent = progress;
            otaDeploying = true;
            otaStage = stage;
            var m = msg.match(/Pulling (.+?) \(/);
            if (m && m[1]) downloadFileName = m[1];
            if (stage === "apply" || stage === "restart") chkDownloaded = true;
            if (stage === "restart" && progress >= 100) chkApplied = true;
        }

        onOtaResult: (guest, success, msg) => {
            /* Send to guest's own bar/tracker again -- never touches the
               Replace -> Apply flow's progressPercent/otaDeploying/
               otaStageLabel below. */
            if (otaPhase === "push") {
                pushingNow = false;
                pushProgressPercent = success ? 100 : 0;
                if (success) {
                    pushDelivered = true;
                    pushStatus = "Files delivered to the guest.";
                    sendModel.clear();
                } else {
                    pushStatus = "Push failed: " + msg;
                }
                otaPhase = "";
                mqtt.refreshGuests();
                return;
            }

            progressPercent = success ? 100 : 0;
            otaDeploying = false;
            otaStageLabel = (success ? "Done — " : "Failed — ") + msg;
            lastOtaSucceeded = success;

            if (success) {
                if (otaPhase === "fetch") {
                    /* doFetch() now sends every pending file as one batched
                       fetchOtaFiles() call (see its comment), so this single
                       ota_result covers the whole batch, not one row picked
                       out by currentStageIdx. Mark every row that was part
                       of it -- still sent && !downloaded at this point,
                       since nothing else can touch stagedModel while a fetch
                       is outstanding -- as downloaded. */
                    var pulled = 0;
                    for (var fi = 0; fi < stagedModel.count; ++fi) {
                        var r = stagedModel.get(fi);
                        if (r.sent && !r.downloaded) {
                            stagedModel.set(fi, {
                                destName: r.destName, local: r.local, serverPath: r.serverPath,
                                sent: true, downloaded: true, state: "done"
                            });
                            pulled++;
                        }
                    }
                    if (pulled > 0)
                        log("success", "Pulled " + pulled + " file(s) down to the host.");
                    otaPhase = "";
                    doFetch();
                    return;
                } else if (otaPhase === "apply") {
                    chkDownloaded = true; chkApplied = true;
                } else {
                    uploadingNow = false;
                }
            } else {
                if (otaPhase === "fetch") {
                    /* Same batch as above: revert every row that was part of
                       this failed fetch, not just one picked out by
                       currentStageIdx. */
                    for (var fj = 0; fj < stagedModel.count; ++fj) {
                        var f = stagedModel.get(fj);
                        if (f.sent && !f.downloaded) {
                            stagedModel.set(fj, {
                                destName: f.destName, local: f.local, serverPath: "",
                                sent: false, downloaded: false, state: ""
                            });
                        }
                    }
                }
                uploadingNow = false;
            }
            otaPhase = "";
            mqtt.refreshGuests();
            if (chkApplied) refreshPartitions();
        }

        onFileStaged: (serverPath, localName) => {
            var dest = serverPath.substring(serverPath.lastIndexOf("/") + 1);
            var ok = false;
            for (var i = 0; i < stagedModel.count; ++i) {
                if (stagedModel.get(i).destName === dest) {
                    var r = stagedModel.get(i);
                    stagedModel.set(i, {
                        destName: dest, local: r.local, serverPath: serverPath,
                        sent: true, downloaded: r.downloaded, state: "uploaded"
                    });
                    ok = true;
                    break;
                }
            }
            if (stagedModel.count > 0 && sentCount() === stagedModel.count)
                chkUploaded = true;
            otaStageLabel = ok
                ? "Uploaded " + localName + " — pulling it down to the host…"
                : "Uploaded " + localName + " to the server.";
            /* Continue the upload loop, not doFetch() directly. uploadNext()
               finds the next staged file that is not yet sent and uploads
               it; only once every file has been sent (its own idx < 0 case)
               does it hand off to doFetch() to start pulling them down.
               Jumping straight to doFetch() here after just the FIRST file
               skipped that loop entirely -- staging more than one file
               uploaded and pulled only the first, then sat there: doFetch()
               only ever looks for rows that are already "sent", and nothing
               else was left to call uploadNext() again for the rest. */
            if (ok) uploadNext();
        }

        onGenericUploaded: (serverPath) => {
            if (!pushingNow) return;
            pushUploaded = true;
            pushStatus = "Archive is on the server — delivering it to the guest…";
            mqtt.pushFilesToGuest(selectedGuestId, serverPath);
        }

        onUploadFailed: (localName, err) => {
            if (pushingNow) {
                pushingNow = false;
                otaPhase = "";
                pushStatus = "Archive upload failed (" + err + ") — press Send again.";
                return;
            }
            uploadingNow = false;
            for (var i = 0; i < stagedModel.count; ++i) {
                var r = stagedModel.get(i);
                if (r.local.indexOf(localName) >= 0 || r.destName === localName) {
                    stagedModel.set(i, {
                        destName: r.destName, local: r.local, serverPath: "",
                        sent: false, downloaded: r.downloaded, state: ""
                    });
                    break;
                }
            }
            otaStageLabel = "Upload of " + localName + " failed (" + err + ") — press Upload to retry.";
        }

        onLogMessage: (text, type) => logPanel.append(type, text)
    }

    /* ======================== chrome ======================== */

    header: ToolBar {
        height: 76
        background: Rectangle {
            color: Theme.surface
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.outline
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingLoose
            anchors.rightMargin: Theme.spacingLoose
            spacing: Theme.spacing

            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true

                Text {
                    text: "Hypervisor Management"
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontTitle
                    font.weight: Font.DemiBold
                }
                Text {
                    text: "MQTT control · SCP delivery via " + mqtt.serverUserHost
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSmall
                }
            }

            /* Connection state */
            Rectangle {
                Layout.preferredHeight: 40
                Layout.preferredWidth: statusRow.implicitWidth + 28
                radius: 20
                color: mqtt.connected ? Theme.successSoft : Theme.dangerSoft

                RowLayout {
                    id: statusRow
                    anchors.centerIn: parent
                    spacing: Theme.spacingTight

                    Rectangle {
                        implicitWidth: 10; implicitHeight: 10
                        radius: 5
                        color: mqtt.connected ? Theme.success : Theme.danger

                        SequentialAnimation on opacity {
                            running: !mqtt.connected
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.25; duration: 700 }
                            NumberAnimation { to: 1.0;  duration: 700 }
                        }
                    }

                    Text {
                        text: mqtt.connected ? mqtt.broker : mqtt.statusText
                        color: mqtt.connected ? Theme.success : Theme.danger
                        font.pixelSize: Theme.fontSmall
                        font.weight: Font.DemiBold
                    }
                }
            }

            /* Board state -- deliberately a SEPARATE pill from the broker one
               above. They answer different questions, and merging them is what
               made a powered-off board look fine: the broker is on the
               internet and stays reachable no matter what the RPi does. */
            Rectangle {
                Layout.preferredHeight: 40
                Layout.preferredWidth: hostRow.implicitWidth + 28
                radius: 20
                color: mqtt.hostOnline ? Theme.successSoft : Theme.dangerSoft

                RowLayout {
                    id: hostRow
                    anchors.centerIn: parent
                    spacing: Theme.spacingTight

                    /* The live pulse. Each beat drives it briefly bright and
                       wide, so a healthy link visibly ticks about once a
                       second and a frozen one is obvious at a glance -- a
                       static dot looks the same either way. */
                    Rectangle {
                        id: beatDot
                        implicitWidth: 10; implicitHeight: 10
                        radius: 5
                        color: mqtt.hostOnline ? Theme.success : Theme.danger
                        opacity: mqtt.hostOnline ? 0.45 : 1.0

                        SequentialAnimation {
                            id: beatPulse
                            NumberAnimation { target: beatDot; property: "opacity"
                                              to: 1.0; duration: 90 }
                            NumberAnimation { target: beatDot; property: "opacity"
                                              to: 0.45; duration: 550 }
                        }

                        /* Blink steadily while offline, instead of the pulse. */
                        SequentialAnimation on scale {
                            running: !mqtt.hostOnline
                            loops: Animation.Infinite
                            NumberAnimation { to: 1.35; duration: 500 }
                            NumberAnimation { to: 1.0;  duration: 500 }
                        }
                    }

                    Text {
                        text: mqtt.hostOnline ? "Board live" : "BOARD OFFLINE"
                        color: mqtt.hostOnline ? Theme.success : Theme.danger
                        font.pixelSize: Theme.fontSmall
                        font.weight: Font.DemiBold
                    }
                }

                Connections {
                    target: mqtt
                    function onHeartbeat() { beatPulse.restart() }
                }

    /* Scripted control (OTA_GUI_CONTROL=<port>). Deliberately drives the same
       entry points a click does -- app.currentPage, monitorPage.refreshNow()
       -- so a scripted run exercises the real paths rather than a
       parallel set that could drift away from them.
       Placed after the mqtt Connections block, not inside it: dropping a
       Connections in the middle of another silently re-parents every handler
       below the insertion point onto the wrong target. */
    Connections {
        target: Control
        function onCommand(verb, arg) {
            mqtt.diag("control", verb + " " + arg)
            if (verb === "page") {
                app.currentPage = parseInt(arg)
            } else if (verb === "guest") {
                /* The Monitor page no longer has anything to select -- it
                   shows the host plus every running guest on its own. "guest"
                   just jumps there now; the argument only used to name which
                   one to look at. */
                app.currentPage = 3
            } else if (verb === "refresh") {
                monitorPage.refreshNow()
            } else if (verb === "cmd") {
                mqtt.publishCommand(arg)
            }
        }
    }

            }

            ToolButton {
                text: Theme.dark ? "☀" : "☾"
                font.pixelSize: Theme.fontTitle
                implicitWidth: 48
                implicitHeight: 48
                Material.foreground: Theme.textSecondary
                ToolTip.visible: hovered
                ToolTip.text: Theme.dark ? "Switch to the light theme"
                                         : "Switch to the dark theme"
                onClicked: Theme.dark = !Theme.dark
            }

            FilledButton {
                text: mqtt.connected ? "Disconnect" : "Connect"
                implicitHeight: Theme.controlHeight
                implicitWidth: 140
                font.pixelSize: Theme.fontBody
                accent: Theme.primary
                onClicked: mqtt.connected ? mqtt.disconnectFromBroker()
                                          : mqtt.connectToBroker()
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        /* ---------------- navigation rail ---------------- */
        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: 228
            color: Theme.surface

            Rectangle {
                anchors.right: parent.right
                width: 1
                height: parent.height
                color: Theme.outline
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.spacingTight
                anchors.topMargin: Theme.spacing
                spacing: 4

                Repeater {
                    model: [
                        { label: "Guests",   glyph: "▤", badge: guestsModel.count },
                        { label: "OTA update", glyph: "⇪", badge: stagedModel.count },
                        { label: "Shell",    glyph: "❯", badge: 0 },
                        { label: "Monitor",  glyph: "◷", badge: 0 },
                        { label: "Log",      glyph: "≡", badge: 0 }
                    ]

                    delegate: Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 52
                        radius: Theme.radiusSmall
                        color: app.currentPage === index ? Theme.primarySoft
                             : navHover.hovered ? Theme.neutralSoft : "transparent"

                        Behavior on color { ColorAnimation { duration: 100 } }

                        HoverHandler { id: navHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: app.currentPage = index }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: 3
                            height: 26
                            radius: 2
                            color: Theme.primary
                            visible: app.currentPage === index
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacing
                            anchors.rightMargin: Theme.spacingTight
                            spacing: Theme.spacingTight

                            Text {
                                text: modelData.glyph
                                color: app.currentPage === index ? Theme.primary
                                                                 : Theme.textSecondary
                                font.pixelSize: Theme.fontLarge
                            }
                            Text {
                                text: modelData.label
                                color: app.currentPage === index ? Theme.primary
                                                                 : Theme.textPrimary
                                font.pixelSize: Theme.fontBody
                                font.weight: app.currentPage === index ? Font.DemiBold
                                                                        : Font.Normal
                                Layout.fillWidth: true
                            }
                            Rectangle {
                                visible: modelData.badge > 0
                                implicitWidth: Math.max(24, badgeText.implicitWidth + 12)
                                implicitHeight: 22
                                radius: 11
                                color: app.currentPage === index ? Theme.primary
                                                                 : Theme.surfaceVariant
                                Text {
                                    id: badgeText
                                    anchors.centerIn: parent
                                    text: modelData.badge
                                    color: app.currentPage === index ? Theme.textOnAccent
                                                                     : Theme.textSecondary
                                    font.pixelSize: Theme.fontTiny
                                    font.weight: Font.DemiBold
                                }
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true }

                Text {
                    Layout.fillWidth: true
                    Layout.margins: Theme.spacingTight
                    text: mqtt.connected ? "Connected" : mqtt.statusText
                    color: Theme.textDisabled
                    font.pixelSize: Theme.fontTiny
                    wrapMode: Text.Wrap
                }
            }
        }

        /* ---------------- pages ---------------- */
        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: Theme.spacingLoose
            currentIndex: app.currentPage
            onCurrentIndexChanged: mqtt.diag("page", "switched to index " + currentIndex)

            GuestsPage {
                mqtt: mqtt; app: app; guestsModel: guestsModel
                /* The Monitor page shows every running guest on its own now,
                   so opening it from a guest row just needs to switch tabs --
                   there is nothing left to select. */
                onOpenMonitor: (id, name, ip, running) => { app.currentPage = 3; }
            }

            OtaPage {
                mqtt: mqtt; app: app
                guestsModel: guestsModel
                partitionsModel: partitionsModel
                stagedModel: stagedModel
                sendModel: sendModel
            }

            ShellPage {
                id: shellPage
                mqtt: mqtt; app: app; guestsModel: guestsModel
            }

            GuestMonitor {
            mqttRef: mqtt
                id: monitorPage
                guests: guestsModel
                /* Also gated on the window being on screen: polling costs a
                   `top` plus an SSH on the host and a few hundred lines of
                   parsing here, and none of that is worth doing for a window
                   the user has minimised. */
                /* Two ways for this page to be off-screen now. The
                   attached Window.visibility reports whichever window the page
                   ends up in -- its own when standalone, Maestro's when in a
                   tab -- and app.visible covers the tab simply not being the
                   one on display, which minimisation alone would miss. */
                active: app.currentPage === 3 && mqtt.connected
                        && app.visible
                        && Window.visibility !== Window.Minimized
                onRequestStats: (id) => mqtt.guestStats(id)
            }

            LogPanel { id: logPanel }
        }
    }

    /* ======================== dialogs ======================== */

    /* ---- guest info ---- */
    Dialog {
        id: infoDialog
        anchors.centerIn: Overlay.overlay
        width: 660
        height: 560
        modal: true
        title: "Guest — " + infoGuestId
        standardButtons: Dialog.Close
        Material.background: Theme.surface

        ListView {
            anchors.fill: parent
            model: infoFields
            spacing: 2
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Rectangle {
                width: ListView.view.width
                height: Math.max(44, valueLabel.implicitHeight + 18)
                radius: Theme.radiusSmall
                color: index % 2 === 0 ? Theme.surfaceSunken : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingTight
                    anchors.rightMargin: Theme.spacingTight
                    spacing: Theme.spacing

                    Text {
                        text: modelData.key
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontSmall
                        font.weight: Font.DemiBold
                        Layout.preferredWidth: 130
                        Layout.alignment: Qt.AlignTop | Qt.AlignLeft
                        Layout.topMargin: 9
                    }
                    Text {
                        id: valueLabel
                        text: modelData.value && modelData.value !== "" ? modelData.value : "—"
                        color: Theme.textPrimary
                        font.family: Theme.monoFamily
                        font.pixelSize: Theme.fontSmall
                        wrapMode: Text.WrapAnywhere
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                    }
                }
            }
        }
    }

    /* ---- local file picker ---- */
    Dialog {
        id: filePicker
        anchors.centerIn: Overlay.overlay
        width: 720
        height: 580
        modal: true
        title: mode === "send" ? "Choose a file to send to the guest"
                               : "Choose a replacement for " + pickerDest
        standardButtons: Dialog.Cancel
        Material.background: Theme.surface

        property string mode: "partition"
        property string selectedFile: ""
        /* Was hardcoded to "/home/gemy/". mqtt.homePath is QDir::homePath().
           Reopens wherever the last pick (Replace or Add file -- they share
           this same dialog) left off, via uiSettings.lastLocalFolder, rather
           than always starting back at the home directory. */
        property url currentFolder: uiSettings.lastLocalFolder !== ""
            ? uiSettings.lastLocalFolder
            : "file://" + mqtt.homePath + "/"

        onOpened: { selectedFile = ""; fileList.currentIndex = -1 }
        onCurrentFolderChanged: {
            selectedFile = ""; fileList.currentIndex = -1;
            uiSettings.lastLocalFolder = currentFolder.toString();
        }

        function choose() {
            if (selectedFile === "") return;
            var localPath = selectedFile.toString().replace("file://", "");
            if (mode === "send") {
                var fname = localPath.substring(localPath.lastIndexOf("/") + 1);
                sendModel.append({ local: localPath, dest: "/" + fname });
                log("info", "Queued " + localPath + " → /" + fname);
            } else if (pickerDest !== "") {
                stagePartition(pickerDest, localPath);
                log("info", "Staged " + localPath + " to replace " + pickerDest);
            }
            pickerDest = "";
            close();
        }

        FolderListModel {
            id: folderModel
            folder: filePicker.currentFolder
            showFiles: true
            showDirs: true
            showDotAndDotDot: false
            sortCaseSensitive: false
            nameFilters: ["*"]
        }

        /* Debounced "genuinely empty" check. FolderListModel's Ready+count=0
           can be momentarily true for a folder that is NOT actually empty --
           every reassignment of `folder` passes through Null first (count 0
           there too, already handled above), and status/count can each land
           on a given value for a single frame while the other one is still
           catching up before both settle. Rather than trust any single
           frame's reading, only call a folder empty once Ready+count=0 has
           held for a beat -- long enough that a real (if brief) transition
           can't be mistaken for it, short enough a genuinely empty folder
           still reports promptly. */
        property bool folderConfirmedEmpty: false
        Timer {
            id: emptyConfirm
            interval: 350
            onTriggered: filePicker.folderConfirmedEmpty = true
        }
        Connections {
            target: folderModel
            function onStatusChanged() { filePicker.recheckEmpty() }
            function onCountChanged() { filePicker.recheckEmpty() }
        }
        function recheckEmpty() {
            if (folderModel.status === FolderListModel.Ready && folderModel.count === 0) {
                if (!folderConfirmedEmpty) emptyConfirm.restart();
            } else {
                emptyConfirm.stop();
                folderConfirmedEmpty = false;
            }
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: Theme.spacingTight

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingTight

                TextField {
                    id: pathField
                    Layout.fillWidth: true
                    Layout.preferredHeight: 42
                    text: filePicker.currentFolder.toString().replace("file://", "")
                    font.family: Theme.monoFamily
                    font.pixelSize: Theme.fontSmall
                    Material.accent: Theme.primary
                    onAccepted: {
                        var p = text.trim();
                        if (p === "") return;
                        if (p[0] !== "/") p = "/" + p;
                        if (!p.endsWith("/")) p += "/";
                        filePicker.currentFolder = "file://" + p;
                    }
                }

                Button {
                    text: "Up"
                    flat: true
                    implicitHeight: 42
                    font.pixelSize: Theme.fontBody
                    enabled: filePicker.currentFolder.toString() !== "file:///"
                    Material.foreground: Theme.primary
                    onClicked: {
                        var url = filePicker.currentFolder.toString();
                        if (url.endsWith("/")) url = url.slice(0, -1);
                        filePicker.currentFolder = url.slice(0, url.lastIndexOf("/") + 1);
                    }
                }

                Button {
                    text: "Home"
                    flat: true
                    implicitHeight: 42
                    font.pixelSize: Theme.fontBody
                    Material.foreground: Theme.primary
                    onClicked: filePicker.currentFolder = "file://" + mqtt.homePath + "/"
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Theme.radiusSmall
                color: Theme.surfaceSunken
                border.color: Theme.outline
                border.width: 1
                clip: true

                ListView {
                    id: fileList
                    anchors.fill: parent
                    anchors.margins: 6
                    model: folderModel
                    spacing: 2
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    delegate: Rectangle {
                        id: fileRow
                        width: fileList.width - 8
                        height: 40
                        radius: Theme.radiusSmall
                        color: fileList.currentIndex === index ? Theme.primarySoft
                             : fileHover.hovered ? Theme.neutralSoft : "transparent"

                        readonly property string filePath: {
                            var url = filePicker.currentFolder.toString();
                            if (!url.endsWith("/")) url += "/";
                            return url + model.fileName;
                        }

                        HoverHandler { id: fileHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: {
                                fileList.currentIndex = index;
                                if (model.fileIsDir)
                                    filePicker.currentFolder = fileRow.filePath + "/";
                                else
                                    filePicker.selectedFile = fileRow.filePath;
                            }
                            onDoubleTapped: {
                                if (model.fileIsDir)
                                    filePicker.currentFolder = fileRow.filePath + "/";
                                else {
                                    filePicker.selectedFile = fileRow.filePath;
                                    filePicker.choose();
                                }
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacingTight
                            anchors.rightMargin: Theme.spacingTight
                            spacing: Theme.spacingTight

                            Text {
                                text: model.fileIsDir ? "▸" : "○"
                                color: model.fileIsDir ? Theme.primary : Theme.textDisabled
                                font.pixelSize: Theme.fontBody
                            }
                            Text {
                                text: model.fileName
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontBody
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                            Text {
                                text: model.fileIsDir ? "" : app.fmtSize(model.fileSize)
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontTiny
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        /* "Empty folder" only once filePicker.recheckEmpty()
                           has confirmed Ready+count=0 held for a beat, not
                           on any single frame -- see the debounce next to
                           folderModel above. Until then this stays hidden
                           rather than guessing "Loading…" either: showing
                           nothing during a folder with real content's brief
                           in-between frames is a lot less alarming than
                           telling the user it's empty and being wrong. */
                        text: "Empty folder"
                        color: Theme.textDisabled
                        font.pixelSize: Theme.fontBody
                        visible: filePicker.folderConfirmedEmpty
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingTight

                Text {
                    Layout.fillWidth: true
                    text: filePicker.selectedFile !== ""
                        ? filePicker.selectedFile.toString().replace("file://", "")
                        : "No file selected"
                    color: filePicker.selectedFile !== "" ? Theme.textPrimary : Theme.textDisabled
                    font.family: Theme.monoFamily
                    font.pixelSize: Theme.fontSmall
                    elide: Text.ElideLeft
                }

                FilledButton {
                    text: "Select"
                    implicitHeight: Theme.controlHeight
                    implicitWidth: 130
                    font.pixelSize: Theme.fontBody
                    enabled: filePicker.selectedFile !== ""
                    accent: Theme.primary
                    onClicked: filePicker.choose()
                }
            }
        }
    }

    /* ---- guest filesystem browser ---- */
    Dialog {
        id: guestBrowser
        anchors.centerIn: Overlay.overlay
        width: 700
        height: 560
        modal: true
        title: "Destination inside " + (selectedGuestId !== "" ? selectedGuestId : "the guest")
        standardButtons: Dialog.Cancel
        Material.background: Theme.surface

        function requestListing() {
            browseModel.clear();
            browseSelected = "";
            lsPending = true;
            mqtt.execCommand(selectedGuestId, "ls -la " + browsePath);
        }

        function parseListing(output) {
            if (!lsPending) return;
            lsPending = false;
            browseModel.clear();
            if (browsePath !== "/")
                browseModel.append({ name: "..", isDir: true, size: "" });
            var lines = output.split("\n");
            for (var i = 0; i < lines.length; ++i) {
                var line = lines[i].trim();
                if (line === "" || line.indexOf("total ") === 0) continue;
                /* mode, links, owner, group, size are always exactly five
                   whitespace-separated fields; everything after them is the
                   timestamp then the name. The timestamp's own shape is NOT
                   fixed across ls implementations: busybox/toybox (the
                   guest images' own ls) print "Mon DD HH:MM" or "Mon DD
                   YYYY" -- three fields -- but QNX's ls prints "YYYY-MM-DD
                   HH:MM", two. Slicing the token array at a fixed index
                   assumed the three-field form, so on a QNX guest every
                   symlink's name came out as "-> target" (the slice landed
                   one token into the arrow) and every OTHER row -- being one
                   token short of the length this function required just to
                   accept it -- was dropped outright: browsing a QNX guest
                   showed next to nothing, and what little showed had the
                   wrong name. Matching the first five fields with a regex
                   and then stripping a recognized timestamp shape off the
                   FRONT of whatever remains reads either format correctly. */
                var m = line.match(/^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.+)$/);
                if (!m) continue;
                var mode = m[1];
                var sizeTok = m[5];
                var dm = m[6].match(
                    /^(?:[A-Za-z]{3}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4})|\d{4}-\d{2}-\d{2}\s+\d{1,2}:\d{2})\s+(.+)$/);
                if (!dm) continue;
                var name = dm[1];
                var cut = name.indexOf(" -> ");
                if (cut > 0) name = name.substring(0, cut);
                if (name === "." || name === "..") continue;
                if (mode[0] === "d")
                    browseModel.append({ name: name, isDir: true, size: "" });
                else if (mode[0] === "-" || mode[0] === "l")
                    browseModel.append({ name: name, isDir: false, size: sizeTok });
            }
        }

        function useCurrent() {
            if (browseRow < 0 || browseRow >= sendModel.count) { close(); return; }
            var r = sendModel.get(browseRow);
            var base = r.local.substring(r.local.lastIndexOf("/") + 1);
            var dest = browseSelected !== "" ? browseSelected
                                             : joinGuestPath(browsePath, base);
            sendModel.set(browseRow, { local: r.local, dest: dest });
            log("info", "Destination for " + base + " set to " + dest);
            close();
        }

        function goUp() {
            var p = browsePath;
            if (p.endsWith("/")) p = p.slice(0, -1);
            var idx = p.lastIndexOf("/");
            browsePath = idx <= 0 ? "/" : p.slice(0, idx);
            requestListing();
        }

        /* Reopens at uiSettings.lastGuestPath (the last place any browse
           left off for any guest) instead of always resetting to root. */
        onOpened: {
            browsePath = uiSettings.lastGuestPath !== "" ? uiSettings.lastGuestPath : "/";
            browseSelected = "";
            requestListing();
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: Theme.spacingTight

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingTight

                TextField {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 42
                    text: browsePath
                    font.family: Theme.monoFamily
                    font.pixelSize: Theme.fontSmall
                    Material.accent: Theme.primary
                    onAccepted: {
                        var p = text.trim();
                        if (p === "") return;
                        if (p[0] !== "/") p = "/" + p;
                        browsePath = p;
                        guestBrowser.requestListing();
                    }
                }
                Button {
                    text: "Up"
                    flat: true
                    implicitHeight: 42
                    font.pixelSize: Theme.fontBody
                    enabled: browsePath !== "/"
                    Material.foreground: Theme.primary
                    onClicked: guestBrowser.goUp()
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Theme.radiusSmall
                color: Theme.surfaceSunken
                border.color: Theme.outline
                border.width: 1
                clip: true

                ListView {
                    anchors.fill: parent
                    anchors.margins: 6
                    model: browseModel
                    spacing: 2
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    delegate: Rectangle {
                        width: ListView.view.width - 8
                        height: 38
                        radius: Theme.radiusSmall
                        color: browseSelected === joinGuestPath(browsePath, model.name)
                            ? Theme.primarySoft
                            : browseHover.hovered ? Theme.neutralSoft : "transparent"

                        HoverHandler { id: browseHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: {
                                if (model.isDir) {
                                    if (model.name === "..") guestBrowser.goUp();
                                    else {
                                        browsePath = joinGuestPath(browsePath, model.name);
                                        guestBrowser.requestListing();
                                    }
                                } else {
                                    browseSelected = joinGuestPath(browsePath, model.name);
                                }
                            }
                            onDoubleTapped: if (!model.isDir) guestBrowser.useCurrent()
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacingTight
                            anchors.rightMargin: Theme.spacingTight
                            spacing: Theme.spacingTight

                            Text {
                                text: model.isDir ? "▸" : "○"
                                color: model.isDir ? Theme.primary : Theme.textDisabled
                                font.pixelSize: Theme.fontBody
                            }
                            Text {
                                text: model.name
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontBody
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                            }
                            Text {
                                text: model.size
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontTiny
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: lsPending ? "Listing " + browsePath + " …" : "Empty"
                        color: Theme.textDisabled
                        font.pixelSize: Theme.fontBody
                        visible: browseModel.count === 0
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingTight

                Text {
                    Layout.fillWidth: true
                    text: browseSelected !== "" ? "Overwrite " + browseSelected
                                                : "Place into " + browsePath
                    color: Theme.textSecondary
                    font.family: Theme.monoFamily
                    font.pixelSize: Theme.fontSmall
                    elide: Text.ElideLeft
                }

                FilledButton {
                    text: "Use this path"
                    implicitHeight: Theme.controlHeight
                    implicitWidth: 170
                    font.pixelSize: Theme.fontBody
                    enabled: !lsPending && browseRow >= 0
                    accent: Theme.primary
                    onClicked: guestBrowser.useCurrent()
                }
            }
        }
    }

    Component.onCompleted: {
        logPanel.append("info", "Started. Connecting to the broker\u2026");
        mqtt.connectToBroker();
    }
}
