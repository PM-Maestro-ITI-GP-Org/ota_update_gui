import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import MqttClient 1.0
import App 1.0

/*
 * Shell for the whole app: window chrome, navigation, the shared models, and
 * the MQTT wiring. The five screens live in their own files.
 *
 * The previous single 1841-line main.qml carried the layout, the state machine
 * and the GitHub-dark palette inline for all of it, which is why the pages had
 * drifted apart visually and why the OTA tab could not be changed without
 * touching everything else.
 */
ApplicationWindow {
    id: app

    /* Roomier by default: the old 1150x680 left the guest table and the OTA
       cards fighting for the same few hundred pixels. */
    width: 1440
    height: 920
    minimumWidth: 1080
    minimumHeight: 700
    visible: true
    title: "Hypervisor Management — OTA Update"

    color: Theme.background

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

    property string infoGuestId: ""
    property var    infoFields: []

    property string pickerDest: ""
    property int    browseRow: -1
    property string browsePath: "/"
    property string browseSelected: ""
    property bool   lsPending: false

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
        var idx = -1;
        for (var i = 0; i < stagedModel.count; ++i)
            if (stagedModel.get(i).sent && !stagedModel.get(i).downloaded) { idx = i; break; }
        if (idx < 0) {
            if (stagedModel.count > 0 && readyCount() === stagedModel.count) {
                chkDownloaded = true;
                uploadingNow = false;
                otaDeploying = false;
                otaStageLabel = "All files are on the host — press Apply to install them.";
            }
            return;
        }
        currentStageIdx = idx;
        setRowState(idx, "downloading");
        otaPhase = "fetch";
        otaDeploying = true;
        chkDownloaded = false; chkApplied = false; otaStage = "";
        var row = stagedModel.get(idx);
        mqtt.fetchOtaFiles(selectedGuestId, [row.serverPath]);
        otaStageLabel = "Pulling " + row.destName + " from the server down to the host…";
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
            progressPercent = percent;
            otaStage = "upload";
            uploadFileName = fileName;
            otaStageLabel = "Uploading " + fileName + " to the server — " + percent + "%";
        }

        onOtaProgress: (guest, stage, progress, msg) => {
            otaStageLabel = msg;
            progressPercent = progress;
            otaDeploying = true;
            otaStage = stage;
            var m = msg.match(/Pulling (.+?) \(/);
            if (m && m[1]) downloadFileName = m[1];
            if (stage === "pushfiles") pushStatus = msg;
            if (stage === "apply" || stage === "restart") chkDownloaded = true;
            if (stage === "restart" && progress >= 100) chkApplied = true;
        }

        onOtaResult: (guest, success, msg) => {
            progressPercent = success ? 100 : 0;
            otaDeploying = false;
            otaStageLabel = (success ? "Done — " : "Failed — ") + msg;

            if (success) {
                if (otaPhase === "fetch") {
                    var r = (currentStageIdx >= 0 && currentStageIdx < stagedModel.count)
                        ? stagedModel.get(currentStageIdx) : null;
                    if (r && r.sent && !r.downloaded) {
                        stagedModel.set(currentStageIdx, {
                            destName: r.destName, local: r.local, serverPath: r.serverPath,
                            sent: true, downloaded: true, state: "done"
                        });
                        log("success", "Pulled " + r.destName + " down to the host.");
                    }
                    otaPhase = "";
                    doFetch();
                    return;
                } else if (otaPhase === "apply") {
                    chkDownloaded = true; chkApplied = true;
                } else if (otaPhase === "push") {
                    pushingNow = false;
                    pushStatus = "Files delivered to the guest.";
                    sendModel.clear();
                } else {
                    uploadingNow = false;
                }
            } else {
                if (otaPhase === "fetch" && currentStageIdx >= 0
                    && currentStageIdx < stagedModel.count) {
                    var f = stagedModel.get(currentStageIdx);
                    stagedModel.set(currentStageIdx, {
                        destName: f.destName, local: f.local, serverPath: "",
                        sent: false, downloaded: false, state: ""
                    });
                } else if (otaPhase === "push") {
                    pushingNow = false;
                    pushStatus = "Push failed: " + msg;
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
            if (ok) doFetch();
        }

        onGenericUploaded: (serverPath) => {
            if (!pushingNow) return;
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
        target: control
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
                active: app.currentPage === 3 && mqtt.connected
                        && app.visibility !== Window.Minimized
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
        /* Was hardcoded to "/home/gemy/". mqtt.homePath is QDir::homePath(). */
        property url currentFolder: "file://" + mqtt.homePath + "/"

        onOpened: { selectedFile = ""; fileList.currentIndex = -1 }
        onCurrentFolderChanged: { selectedFile = ""; fileList.currentIndex = -1 }

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
                        text: folderModel.status === FolderListModel.Loading
                            ? "Loading…" : "Empty folder"
                        color: Theme.textDisabled
                        font.pixelSize: Theme.fontBody
                        visible: folderModel.count === 0
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
                var toks = line.split(/\s+/);
                if (toks.length < 9) continue;
                var mode = toks[0];
                var name = toks.slice(8).join(" ");
                var cut = name.indexOf(" -> ");
                if (cut > 0) name = name.substring(0, cut);
                if (name === "." || name === "..") continue;
                if (mode[0] === "d")
                    browseModel.append({ name: name, isDir: true, size: "" });
                else if (mode[0] === "-" || mode[0] === "l")
                    browseModel.append({ name: name, isDir: false, size: toks[4] });
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

        onOpened: { browsePath = "/"; browseSelected = ""; requestListing() }

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
