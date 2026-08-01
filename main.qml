import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import MqttClient 1.0

ApplicationWindow {
    id: win
    width: 1150
    height: 680
    minimumWidth: 780
    minimumHeight: 560
    visible: true
    title: "OTA Update & Hypervisor Management"

    color: "#0d1117"

    MqttClient {
        id: mqtt

        onGuestListReceived: (json) => {
            var obj = JSON.parse(json)
            guestsModel.clear()
            for (var i = 0; i < obj.guests.length; ++i) {
                var g = obj.guests[i]
                guestsModel.append({
                    id: g.id,
                    name: g.name || "-",
                    type: g.type,
                    state: g.state,
                    pid: g.pid,
                    ip: g.ip,
                    running: g.state === "running"
                })
            }
            guestsLoading = false
            updateGuestCombo()
            lastUpdateText = "Updated " + new Date().toLocaleTimeString(Qt.locale("en_US"), "hh:mm:ss")
            logPanel.append("info", "Guest list: " + guestsModel.count + " guest(s) found.")
        }

        onGuestInfoReceived: (json) => {
            var obj = JSON.parse(json)
            infoGuestId = obj.guest.id
            infoFields = [
                { "key": "ID",       "value": obj.guest.id },
                { "key": "Name",     "value": obj.guest.name },
                { "key": "Type",     "value": obj.guest.type },
                { "key": "State",    "value": obj.guest.state },
                { "key": "PID",      "value": String(obj.guest.pid) },
                { "key": "IP",       "value": obj.guest.ip },
                { "key": "Config",   "value": obj.guest.conf },
                { "key": "Boot",     "value": obj.guest.boot },
                { "key": "RootFS",   "value": obj.guest.rootfs },
                { "key": "SSH User", "value": obj.guest.ssh_user },
                { "key": "SSH Port", "value": String(obj.guest.ssh_port) },
                { "key": "SSH Key",  "value": obj.guest.ssh_key }
            ]
            infoDialog.open()
        }

        onCmdResult: (cmd, guest, success, msg) => {
            if (cmd === "start" || cmd === "kill")
                mqtt.refreshGuests()
        }

        onExecOutput: (guest, output) => {
            if (guestBrowser.opened) guestBrowser.parseListing(output)
            else shellOutput.text = output
        }

        onUploadProgress: (percent, fileName) => {
            progressPercent = percent
            otaStage = "upload"
            uploadFileName = fileName
            otaStageLabel.text = "Upload " + fileName + " to server: " + percent + "%"
            if (percent >= 100)
                logPanel.append("info", "Upload " + fileName + " to server complete (100%)")
        }

        onOtaProgress: (guest, stage, progress, msg) => {
            if (stage !== otaStage)
                logPanel.append("info", "OTA stage \"" + stage + "\" started for " + guest + ": " + msg)
            otaStageLabel.text = stage + " — " + msg
            progressPercent = progress
            otaDeploying = true
            otaStage = stage
            /* The RPi reports the current file in the message, e.g.
               "Pulling qnx-guest.ifs (29835/43228 KB)" — show it in the bar. */
            var m = msg.match(/Pulling (.+?) \(/)
            if (m && m[1]) downloadFileName = m[1]
            if (stage === "pushfiles") pushStatus = msg
            if (stage === "apply" || stage === "restart") chkDownloaded = true
            if (stage === "restart" && progress >= 100) chkApplied = true
            if (progress >= 100)
                logPanel.append("info", "OTA stage \"" + stage + "\" completed for " + guest + " (" + progress + "%)")
        }

        onOtaResult: (guest, success, msg) => {
            progressPercent = success ? 100 : 0
            otaDeploying = false
            otaStageLabel.text = (success ? "DONE — " : "FAILED — ") + msg
            if (success) {
                if (otaPhase === "fetch") {
                    var r = (currentStageIdx >= 0) ? stagedModel.get(currentStageIdx) : null
                    if (r && r.sent && !r.downloaded) {
                        stagedModel.set(currentStageIdx, {
                            destName: r.destName, local: r.local, serverPath: r.serverPath,
                            sent: true, downloaded: true, state: "done"
                        })
                        logPanel.append("success", "Downloaded " + r.destName + " to the RPi stage dir")
                    }
                    uploadNext()
                } else if (otaPhase === "apply") {
                    chkDownloaded = true; chkApplied = true
                } else if (otaPhase === "push") {
                    pushingNow = false
                    pushStatus = "Files pushed to guest."
                    sendModel.clear()
                    logPanel.append("success", "Files pushed to guest: " + msg)
                } else {
                    uploadingNow = false
                }
            } else {
                if (otaPhase === "fetch" && currentStageIdx >= 0) {
                    var f = stagedModel.get(currentStageIdx)
                    if (f)
                        stagedModel.set(currentStageIdx, {
                            destName: f.destName, local: f.local, serverPath: "",
                            sent: false, downloaded: false, state: ""
                        })
                } else if (otaPhase === "push") {
                    pushingNow = false
                    pushStatus = "Push failed: " + msg
                }
                uploadingNow = false
            }
            otaPhase = ""
            logPanel.append(success ? "success" : "error", "OTA " + (success ? "OK" : "FAILED") + " for " + guest + ": " + msg)
            mqtt.refreshGuests()
            if (chkApplied) refreshPartitions()
        }

        onGuestFilesReceived: (json) => {
            loadPartitions(json)
        }

        onGenericUploaded: (serverPath) => {
            if (!pushingNow) return
            pushStatus = "Archive on the server — sending to guest..."
            mqtt.pushFilesToGuest(selectedGuestId(), serverPath)
        }

        onUploadFailed: (localName, err) => {
            if (pushingNow) {
                pushingNow = false
                otaPhase = ""
                pushStatus = "Archive upload failed (" + err + ") — press Send to guest again."
                logPanel.append("error", "Archive upload failed — press Send to guest again: " + err)
                return
            }
            uploadingNow = false
            var found = false
            for (var i = 0; i < stagedModel.count; ++i) {
                var r = stagedModel.get(i)
                if (r.local.indexOf(localName) >= 0 || r.destName === localName) {
                    stagedModel.set(i, {
                        destName: r.destName, local: r.local, serverPath: "",
                        sent: false, downloaded: r.downloaded, state: ""
                    })
                    found = true
                    break
                }
            }
            otaStageLabel.text = "Upload of " + localName + " failed (" + err + ") — press Upload to retry."
            logPanel.append("error", "Upload of " + localName + " failed — press Upload to retry: " + err)
        }

        onFileStaged: (serverPath, localName) => {
            var dest = serverPath.substring(serverPath.lastIndexOf("/") + 1)
            var ok = false
            for (var i = 0; i < stagedModel.count; ++i) {
                if (stagedModel.get(i).destName === dest) {
                    var r = stagedModel.get(i)
                    stagedModel.set(i, {
                        destName: dest, local: r.local,
                        serverPath: serverPath, sent: true, downloaded: r.downloaded,
                        state: "uploaded"
                    })
                    ok = true
                    break
                }
            }
            otaStageLabel.text = ok
                ? "Uploaded " + localName + " as " + dest + " — downloading to RPi..."
                : "Uploaded " + localName + " on server (not a guest partition)"
            if (sentCount() === stagedModel.count)
                chkUploaded = true
            if (ok) doFetch()
        }

        onLogMessage: (text, type) => logPanel.append(type, text)
    }

    /* ============================ Models & state ============================ */

    ListModel { id: guestsModel }

    ListModel { id: guestComboModel }

    property bool suppressGuestRefresh: false

    function updateGuestCombo() {
        var prev = guestPicker.currentIndex
        suppressGuestRefresh = true
        guestComboModel.clear()
        for (var i = 0; i < guestsModel.count; ++i) {
            var g = guestsModel.get(i)
            guestComboModel.append({ "text": g.id + "  (" + g.state + ")" })
        }
        if (guestComboModel.count === 0)
            guestComboModel.append({ "text": "(no guests)" })
        guestPicker.currentIndex = (prev >= 0 && prev < guestComboModel.count) ? prev : 0
        suppressGuestRefresh = false
    }

    property bool guestsLoading: false
    property string lastUpdateText: ""
    property bool otaDeploying: false
    property bool uploadingNow: false
    property bool pushingNow: false
    property bool otaBusy: otaDeploying || uploadingNow || pushingNow
    property string infoGuestId: ""
    property var infoFields: []
    property string pickedFilePath: ""
    property string pickerDest: ""
    property string pickerMode: "partition"
    property string pushStatus: ""

    /* OTA partition-update state */
    property string currentGuestType: ""

    /* Checklist (X/3): 1 upload to server, 2 download to RPi, 3 apply & restart */
    property bool chkUploaded: false
    property bool chkDownloaded: false
    property bool chkApplied: false
    property string otaStage: ""
    property real progressPercent: 0
    property string uploadFileName: ""
    property string downloadFileName: ""
    property string otaPhase: ""
    property int currentStageIdx: -1

    ListModel { id: partitionsModel }   /* name, kind, exists, size (info only) */
    ListModel { id: stagedModel }       /* destName, local, serverPath, sent, downloaded, state */
    ListModel { id: sendModel }         /* local, dest (absolute path in the guest) */
    ListModel { id: browseModel }       /* name, isDir, size (guest filesystem listing) */

    /* Guest filesystem browser state */
    property string browsePath: "/"
    property string browseSelected: ""
    property int browseRow: -1
    property bool lsPending: false

    function joinGuestPath(base, name) {
        if (base === "/") return "/" + name;
        if (base.endsWith("/")) return base + name;
        return base + "/" + name;
    }

    function selectedGuestId() {
        return guestsModel.count > 0 && guestPicker.currentIndex >= 0
            ? guestsModel.get(guestPicker.currentIndex).id : ""
    }

    function fmtSize(bytes) {
        if (bytes >= 1048576) return (bytes/1048576).toFixed(1) + " MB";
        if (bytes >= 1024) return (bytes/1024).toFixed(1) + " KB";
        if (bytes > 0) return bytes + " B";
        return "-";
    }

    function refreshPartitions() {
        if (selectedGuestId() !== "")
            mqtt.guestFiles(selectedGuestId());
    }

    function loadPartitions(json) {
        partitionsModel.clear();
        stagedModel.clear();
        chkUploaded = false; chkDownloaded = false; chkApplied = false; otaStage = "";
        otaPhase = ""; currentStageIdx = -1;
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
            logPanel.append("error", "Failed to parse guest_files: " + e.message);
        }
    }

    function stagePartition(destName, localPath) {
        chkUploaded = false; chkDownloaded = false; chkApplied = false;
        for (var i = 0; i < stagedModel.count; ++i) {
            if (stagedModel.get(i).destName === destName) {
                stagedModel.set(i, { destName: destName, local: localPath, serverPath: "", sent: false, downloaded: false, state: "" });
                return;
            }
        }
        stagedModel.append({ destName: destName, local: localPath, serverPath: "", sent: false, downloaded: false, state: "" });
    }

    function sentCount() {
        var n = 0;
        for (var i = 0; i < stagedModel.count; ++i)
            if (stagedModel.get(i).sent) n++;
        return n;
    }

    function chkDone() {
        return (chkUploaded ? 1 : 0) + (chkDownloaded ? 1 : 0) + (chkApplied ? 1 : 0)
    }
    function stepColor(done, active) { return done ? "#3fb950" : (active ? "#1f6feb" : "#30363d") }
    function step1Active() { return !chkUploaded && stagedModel.count > 0 }
    function step2Active() { return otaDeploying && !chkDownloaded }
    function step3Active() { return otaDeploying && chkDownloaded && !chkApplied }

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

    /* Per-file step chips (step 1=Upload, 2=Download, 3=Done):
       green = step finished, blue = current step, gray = not reached yet */
    function fileStepColor(state, step) {
        if (state === "uploading")   return step === 1 ? "#1f6feb" : "#30363d";
        if (state === "uploaded")    return step === 1 ? "#3fb950" : "#30363d";
        if (state === "downloading") return step === 1 ? "#3fb950" : (step === 2 ? "#1f6feb" : "#30363d");
        if (state === "done")        return "#3fb950";
        return "#30363d";
    }
    function fileStepDone(state, step) {
        if (state === "uploaded" || state === "downloading") return step === 1;
        if (state === "done") return true;
        return false;
    }

    /* One file at a time: upload it, then download it, then move to the next */
    function sendAll() {
        if (uploadingNow) return;
        uploadingNow = true;
        chkUploaded = false; chkDownloaded = false; chkApplied = false; otaStage = "";
        otaPhase = "upload";
        for (var i = 0; i < stagedModel.count; ++i) {
            var r = stagedModel.get(i);
            if (!r.downloaded)
                stagedModel.set(i, {
                    destName: r.destName, local: r.local, serverPath: r.sent ? r.serverPath : "",
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
        logPanel.append("info", "Uploading " + row.local + " -> " + row.destName);
        mqtt.uploadOtaFile(row.local, row.destName);
    }

    function sentServerPaths() {
        var a = [];
        for (var i = 0; i < stagedModel.count; ++i)
            if (stagedModel.get(i).sent)
                a.push(stagedModel.get(i).serverPath);
        return a;
    }

    /* Download the next sent-but-not-yet-downloaded file to the RPi stage dir */
    function doFetch() {
        var idx = -1;
        for (var i = 0; i < stagedModel.count; ++i)
            if (stagedModel.get(i).sent && !stagedModel.get(i).downloaded) { idx = i; break; }
        if (idx < 0) {
            if (readyCount() === stagedModel.count) {
                chkDownloaded = true;
                uploadingNow = false;
                otaDeploying = false;
                otaStageLabel.text = "All files downloaded to the RPi — press Apply.";
            }
            return;
        }
        currentStageIdx = idx;
        setRowState(idx, "downloading");
        otaPhase = "fetch";
        otaDeploying = true;
        chkDownloaded = false; chkApplied = false; otaStage = "";
        var row = stagedModel.get(idx);
        mqtt.fetchOtaFiles(selectedGuestId(), [row.serverPath]);
        otaStageLabel.text = "Fetching " + row.destName + " from the server to the RPi (stage dir)...";
    }

    function doApply() {
        mqtt.applyOtaFiles(selectedGuestId(), true);
        otaStageLabel.text = "Applying: killing guest, replacing partitions, restarting...";
        otaDeploying = true;
        otaPhase = "apply";
        chkDownloaded = false; chkApplied = false; otaStage = "";
    }

    /* ============================ Send files to guest ============================ */

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
        if (sendModel.count === 0) {
            logPanel.append("error", "No files to send — press Add file first.");
            return;
        }
        if (!allSendDestSet()) {
            logPanel.append("error", "Set a destination path in the guest for every file.");
            return;
        }
        if (selectedGuestId() === "") {
            logPanel.append("error", "Select a guest first.");
            return;
        }
        pushStatus = "Building tar.gz with " + sendModel.count + " file(s)...";
        pushingNow = true;
        otaPhase = "push";
        var tarPath = mqtt.buildPushTar(sendEntriesList(), "/tmp/pushfiles.tar.gz");
        if (tarPath === "") {
            pushingNow = false;
            otaPhase = "";
            pushStatus = "Failed to build the archive.";
            return;
        }
        pushStatus = "Uploading archive to the server...";
        mqtt.uploadGenericFile(tarPath, "pushfiles.tar.gz");
    }

    /* ============================ File picker dialog ============================ */

    Dialog {
        id: fileDialog
        modal: true
        width: 620
        height: 480
        anchors.centerIn: parent
        standardButtons: Dialog.NoButton
        background: Rectangle { color: "#161b22"; radius: 8; border.color: "#30363d"; border.width: 1 }

        property url currentFolder: "file://" + (pickedFilePath !== "" ? pickedFilePath.slice(0, pickedFilePath.lastIndexOf("/") + 1) : homePath())
        property string selectedFile: ""
        property string pickerMode: "partition"

        function homePath() {
            return "/home/gemy/"
        }

        onOpened: {
            fileListView.currentIndex = -1
            fileDialog.selectedFile = ""
        }

        onCurrentFolderChanged: fileListView.currentIndex = -1

        FolderListModel {
            id: fileListModel
            folder: fileDialog.currentFolder
            showFiles: true
            showDirs: true
            sortCaseSensitive: false
            nameFilters: ["*"]
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 28
                    color: "#0d1117"
                    radius: 4
                    border.color: "#30363d"
                    clip: true

                    TextField {
                        id: pathInput
                        anchors.fill: parent
                        text: fileDialog.currentFolder.toString().replace("file://", "")
                        color: "#e6edf3"
                        placeholderText: "/path/to/folder"
                        placeholderTextColor: "#8b949e"
                        font.pixelSize: 11
                        leftPadding: 6
                        verticalAlignment: Text.AlignVCenter
                        selectByMouse: true
                        background: Rectangle { color: "transparent" }
                        onAccepted: {
                            var p = pathInput.text.trim()
                            if (p === "") return
                            if (p[0] !== "/") p = "/" + p
                            if (!p.endsWith("/")) p += "/"
                            fileDialog.currentFolder = "file://" + p
                        }
                    }
                }

                Button {
                    text: "\u2191"
                    implicitWidth: 36; implicitHeight: 28
                    enabled: fileDialog.currentFolder.toString() !== "file:///"
                    onClicked: {
                        var url = fileDialog.currentFolder.toString()
                        if (url.endsWith("/")) url = url.slice(0, -1)
                        var idx = url.lastIndexOf("/")
                        fileDialog.currentFolder = url.slice(0, idx + 1)
                    }
                    contentItem: Text { text: "\u2191"; color: "#e6edf3"; font.bold: true; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#0d1117"
                radius: 6
                border.color: "#30363d"
                clip: true

                ListView {
                    id: fileListView
                    anchors.fill: parent
                    anchors.margins: 4
                    model: fileListModel
                    spacing: 2

                    delegate: Rectangle {
                        width: fileListView.width
                        height: 32
                        color: ListView.isCurrentItem ? "#1f6feb30" : mouseArea.containsMouse ? "#1f6feb15" : "transparent"
                        radius: 4

                        property string filePath: {
                            var url = fileDialog.currentFolder.toString()
                            if (!url.endsWith("/")) url += "/"
                            return url + model.fileName
                        }

                        MouseArea {
                            id: mouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                fileListView.currentIndex = index
                                if (model.fileIsDir)
                                    fileDialog.currentFolder = filePath + "/"
                                else
                                    fileDialog.selectedFile = filePath
                            }
                            onDoubleClicked: {
                                if (model.fileIsDir)
                                    fileDialog.currentFolder = filePath + "/"
                                else
                                    fileDialog.accept()
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8

                            Text {
                                text: model.fileIsDir ? "\u25B6" : "\u25CB"
                                color: "#8b949e"; font.pixelSize: 12
                            }

                            Text {
                                text: model.fileName
                                color: "#e6edf3"; font.pixelSize: 12
                                Layout.fillWidth: true; elide: Text.ElideRight
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: fileListModel.status === FolderListModel.Loading ? "Loading..." : "(empty folder)"
                        color: "#8b949e"; font.pixelSize: 13
                        visible: fileListModel.status !== FolderListModel.Ready && fileListModel.count === 0
                    }
                    Text {
                        anchors.centerIn: parent
                        text: "(empty folder)"
                        color: "#8b949e"; font.pixelSize: 13
                        visible: fileListModel.status === FolderListModel.Ready && fileListModel.count === 0
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Button {
                    text: "Select This File"
                    Layout.fillWidth: true
                    enabled: fileDialog.selectedFile !== ""
                    onClicked: fileDialog.accept()
                    contentItem: Text { text: parent.text; color: "#ffffff"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 13 }
                    background: Rectangle { color: parent.down ? "#1f6feb" : parent.enabled ? "#238636" : "#21262d"; radius: 6 }
                    implicitHeight: 34
                }

                Button {
                    text: "Cancel"
                    Layout.fillWidth: true
                    onClicked: fileDialog.reject()
                    contentItem: Text { text: parent.text; color: "#e6edf3"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 13 }
                    background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 6; border.color: "#30363d"; border.width: 1 }
                    implicitHeight: 34
                }
            }
        }

        onAccepted: {
            var localPath = fileDialog.selectedFile.toString().replace("file://", "")
            win.pickedFilePath = localPath

            if (fileDialog.pickerMode === "send") {
                var fname = localPath.substring(localPath.lastIndexOf("/") + 1)
                sendModel.append({ local: localPath, dest: "/" + fname })
                logPanel.append("info", "Added " + localPath + " to send list (dest: /" + fname + ")")
            } else if (pickerDest !== "") {
                var found = false
                for (var i = 0; i < partitionsModel.count; ++i)
                    if (partitionsModel.get(i).name === pickerDest) { found = true; break }
                logPanel.append("info", "Staged " + localPath + " for partition " + pickerDest
                                + (found ? "" : " (not found on guest)"))
                stagePartition(pickerDest, localPath)
            } else {
                logPanel.append("info", "Selected file: " + localPath)
            }
            pickerDest = ""
            fileDialog.pickerMode = "partition"
        }
    }

    /* ============================ Guest filesystem browser ============================ */

    Dialog {
        id: guestBrowser
        modal: true
        width: 640
        height: 460
        anchors.centerIn: parent
        standardButtons: Dialog.NoButton
        background: Rectangle { color: "#161b22"; radius: 8; border.color: "#30363d"; border.width: 1 }

        function requestListing() {
            browseModel.clear()
            browseSelected = ""
            lsPending = true
            mqtt.execCommand(selectedGuestId(), "ls -la " + browsePath)
        }

        function parseListing(output) {
            if (!lsPending) return
            lsPending = false
            browseModel.clear()
            if (browsePath !== "/")
                browseModel.append({ name: "..", isDir: true, size: "-" })
            var lines = output.split("\n")
            for (var i = 0; i < lines.length; ++i) {
                var line = lines[i].trim()
                if (line === "" || line.indexOf("total ") === 0) continue
                var toks = line.split(/\s+/)
                if (toks.length < 9) continue
                var mode = toks[0]
                var name = toks.slice(8).join(" ")
                var cut = name.indexOf(" -> ")
                if (cut > 0) name = name.substring(0, cut)
                if (name === "." || name === "..") continue
                if (mode[0] === "d")
                    browseModel.append({ name: name, isDir: true, size: "-" })
                else if (mode[0] === "-" || mode[0] === "l")
                    browseModel.append({ name: name, isDir: false, size: toks[4] })
            }
        }

        function useThisPath() {
            if (browseRow < 0 || browseRow >= sendModel.count) { guestBrowser.reject(); return }
            var r = sendModel.get(browseRow)
            var base = r.local.substring(r.local.lastIndexOf("/") + 1)
            var dest = browseSelected !== "" ? browseSelected : joinGuestPath(browsePath, base)
            sendModel.set(browseRow, { local: r.local, dest: dest })
            logPanel.append("info", "Dest for " + base + " set to " + dest)
            guestBrowser.reject()
        }

        onOpened: {
            browsePath = "/"
            browseSelected = ""
            requestListing()
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 8

            Text {
                text: "Destination in guest " + (selectedGuestId() !== "" ? "(" + selectedGuestId() + ")" : "") + " — navigate and choose"
                color: "#e6edf3"; font.pixelSize: 14; font.bold: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 28
                    color: "#0d1117"
                    radius: 4
                    border.color: "#30363d"
                    clip: true
                    TextField {
                        id: browsePathInput
                        anchors.fill: parent
                        text: browsePath
                        color: "#e6edf3"
                        placeholderText: "/path/in/guest"
                        placeholderTextColor: "#8b949e"
                        font.pixelSize: 11
                        leftPadding: 6
                        verticalAlignment: Text.AlignVCenter
                        selectByMouse: true
                        background: Rectangle { color: "transparent" }
                        onAccepted: {
                            var p = browsePathInput.text.trim()
                            if (p === "") return
                            if (p[0] !== "/") p = "/" + p
                            browsePath = p
                            guestBrowser.requestListing()
                        }
                    }
                }
                Button {
                    text: "\u2191"
                    implicitWidth: 36; implicitHeight: 28
                    enabled: browsePath !== "/"
                    onClicked: {
                        var p = browsePath
                        if (p.endsWith("/")) p = p.slice(0, -1)
                        var idx = p.lastIndexOf("/")
                        browsePath = idx <= 0 ? "/" : p.slice(0, idx)
                        guestBrowser.requestListing()
                    }
                    contentItem: Text { text: "\u2191"; color: "#e6edf3"; font.bold: true; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#0d1117"
                radius: 6
                border.color: "#30363d"
                clip: true

                ListView {
                    id: browseList
                    anchors.fill: parent
                    anchors.margins: 4
                    model: browseModel
                    spacing: 2

                    delegate: Rectangle {
                        width: browseList.width
                        height: 28
                        color: browseSelected === joinGuestPath(browsePath, model.name)
                            ? "#1f6feb30" : mouseArea.containsMouse ? "#1f6feb15" : "transparent"
                        radius: 4

                        MouseArea {
                            id: mouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                if (model.isDir) {
                                    if (model.name === "..") {
                                        var p = browsePath
                                        if (p.endsWith("/")) p = p.slice(0, -1)
                                        var idx = p.lastIndexOf("/")
                                        browsePath = idx <= 0 ? "/" : p.slice(0, idx)
                                    } else {
                                        browsePath = joinGuestPath(browsePath, model.name)
                                    }
                                    guestBrowser.requestListing()
                                } else {
                                    browseSelected = joinGuestPath(browsePath, model.name)
                                }
                            }
                            onDoubleClicked: {
                                if (!model.isDir) guestBrowser.useThisPath()
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8
                            Text {
                                text: model.isDir ? "\u25B6" : "\u25CB"
                                color: "#8b949e"; font.pixelSize: 12
                            }
                            Text {
                                text: model.name
                                color: "#e6edf3"; font.pixelSize: 12
                                Layout.fillWidth: true; elide: Text.ElideMiddle
                            }
                            Text {
                                text: model.size
                                color: "#8b949e"; font.pixelSize: 11
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: lsPending ? "Listing " + browsePath + " ..." : "(empty)"
                        color: "#8b949e"; font.pixelSize: 13
                        visible: browseModel.count === 0
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Button {
                    text: "Use this path"
                    Layout.fillWidth: true
                    enabled: browseRow >= 0 && !lsPending
                    onClicked: guestBrowser.useThisPath()
                    contentItem: Text { text: parent.text; color: "#ffffff"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 13 }
                    background: Rectangle { color: parent.down ? "#1f6feb" : parent.enabled ? "#238636" : "#21262d"; radius: 6 }
                    implicitHeight: 34
                }

                Button {
                    text: "Cancel"
                    Layout.fillWidth: true
                    onClicked: guestBrowser.reject()
                    contentItem: Text { text: parent.text; color: "#e6edf3"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 13 }
                    background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 6; border.color: "#30363d"; border.width: 1 }
                    implicitHeight: 34
                }
            }
        }
    }

    /* ============================ Guest info dialog ============================ */

    Popup {
        id: infoDialog
        modal: true
        width: 640
        height: 460
        anchors.centerIn: parent
        background: Rectangle { color: "#161b22"; radius: 8; border.color: "#30363d"; border.width: 1 }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10

            Text {
                text: "Guest Info — " + infoGuestId
                color: "#e6edf3"; font.pixelSize: 16; font.bold: true
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#0d1117"
                radius: 6
                border.color: "#30363d"
                clip: true

                ListView {
                    id: infoList
                    anchors.fill: parent
                    anchors.margins: 6
                    model: infoFields
                    spacing: 4

                    delegate: RowLayout {
                        width: parent.width
                        spacing: 10

                        Text {
                            text: modelData.key + ":"
                            color: "#8b949e"; font.pixelSize: 12
                            font.bold: true
                            Layout.preferredWidth: 110
                        }
                        Text {
                            text: modelData.value
                            color: "#e6edf3"; font.pixelSize: 12
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }

            Button {
                text: "Close"
                Layout.fillWidth: true
                implicitHeight: 34
                onClicked: infoDialog.close()
                contentItem: Text { text: parent.text; color: "#ffffff"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 13 }
                background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 6; border.color: "#30363d"; border.width: 1 }
            }
        }
    }

    /* ============================ Start guest dialog ============================ */

    Popup {
        id: startDialog
        modal: true
        width: 420
        height: 220
        anchors.centerIn: parent
        background: Rectangle { color: "#161b22"; radius: 8; border.color: "#30363d"; border.width: 1 }

        property string guestId: ""

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            Text {
                text: "Start guest " + startDialog.guestId
                color: "#e6edf3"; font.pixelSize: 16; font.bold: true
            }

            Text {
                text: "Optional IP address (used for SSH access to the guest):"
                color: "#8b949e"; font.pixelSize: 12
            }

            TextField {
                id: ipInput
                Layout.fillWidth: true
                placeholderText: "e.g. 192.168.1.50 (leave empty to skip)"
                color: "#e6edf3"
                placeholderTextColor: "#8b949e"
                background: Rectangle { color: "#0d1117"; radius: 4; border.color: "#30363d"; border.width: 1 }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Button {
                    text: "Start"
                    Layout.fillWidth: true
                    implicitHeight: 34
                    onClicked: {
                        mqtt.startGuest(startDialog.guestId, ipInput.text.trim())
                        startDialog.close()
                        ipInput.text = ""
                    }
                    contentItem: Text { text: parent.text; color: "#ffffff"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 13 }
                    background: Rectangle { color: parent.hovered ? "#1f6feb" : "#238636"; radius: 6 }
                }

                Button {
                    text: "Cancel"
                    Layout.fillWidth: true
                    implicitHeight: 34
                    onClicked: { startDialog.close(); ipInput.text = "" }
                    contentItem: Text { text: parent.text; color: "#e6edf3"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 13 }
                    background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 6; border.color: "#30363d"; border.width: 1 }
                }
            }
        }
    }

    /* ============================ Layout ============================ */

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 12

        /* Header */
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 64
            radius: 8
            color: "#161b22"
            border.color: "#30363d"
            border.width: 1

            RowLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    Text {
                        text: "OTA Update & Hypervisor Management"
                        color: "#e6edf3"; font.pixelSize: 18; font.bold: true
                    }
                    Text {
                        text: "MQTT commands + SCP file transfer via server (" + mqtt.serverUserHost + ")"
                        color: "#8b949e"; font.pixelSize: 11
                    }
                }

                Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }

                Rectangle {
                    implicitWidth: 12; implicitHeight: 12
                    radius: 6
                    color: mqtt.connected ? "#3fb950" : "#f85149"
                }

                Text {
                    text: mqtt.connected ? mqtt.broker : ""
                    color: mqtt.connected ? "#7ee787" : "#8b949e"; font.pixelSize: 12; font.bold: mqtt.connected
                    Layout.alignment: Qt.AlignRight
                }

                Button {
                    text: mqtt.connected ? "Disconnect" : "Connect"
                    implicitWidth: 110; implicitHeight: 30
                    Layout.alignment: Qt.AlignRight
                    onClicked: mqtt.connected ? mqtt.disconnectFromBroker() : mqtt.connectToBroker()
                    contentItem: Text { text: parent.text; color: "#ffffff"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 13 }
                    background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 6; border.color: "#30363d"; border.width: 1 }
                }
            }
        }

        /* Tabs */
        TabBar {
            id: tabBar
            Layout.fillWidth: true

            TabButton {
                text: "Guests"
                contentItem: Text { text: parent.text; color: tabBar.currentIndex === 0 ? "#ffffff" : "#8b949e"; font.bold: tabBar.currentIndex === 0; font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter }
                background: Rectangle { color: tabBar.currentIndex === 0 ? "#1f6feb" : "#21262d"; radius: 8; border.color: tabBar.currentIndex === 0 ? "#1f6feb" : "#30363d"; border.width: 1 }
            }
            TabButton {
                text: "OTA Update"
                contentItem: Text { text: parent.text; color: tabBar.currentIndex === 1 ? "#ffffff" : "#8b949e"; font.bold: tabBar.currentIndex === 1; font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter }
                background: Rectangle { color: tabBar.currentIndex === 1 ? "#1f6feb" : "#21262d"; radius: 8; border.color: tabBar.currentIndex === 1 ? "#1f6feb" : "#30363d"; border.width: 1 }
            }
            TabButton {
                text: "Remote Shell"
                contentItem: Text { text: parent.text; color: tabBar.currentIndex === 2 ? "#ffffff" : "#8b949e"; font.bold: tabBar.currentIndex === 2; font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter }
                background: Rectangle { color: tabBar.currentIndex === 2 ? "#1f6feb" : "#21262d"; radius: 8; border.color: tabBar.currentIndex === 2 ? "#1f6feb" : "#30363d"; border.width: 1 }
            }
            TabButton {
                text: "Log"
                contentItem: Text { text: parent.text; color: tabBar.currentIndex === 3 ? "#ffffff" : "#8b949e"; font.bold: tabBar.currentIndex === 3; font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter }
                background: Rectangle { color: tabBar.currentIndex === 3 ? "#1f6feb" : "#21262d"; radius: 8; border.color: tabBar.currentIndex === 3 ? "#1f6feb" : "#30363d"; border.width: 1 }
            }
            TabButton {
                text: "Monitor"
                contentItem: Text { text: parent.text; color: tabBar.currentIndex === 4 ? "#ffffff" : "#8b949e"; font.bold: tabBar.currentIndex === 4; font.pixelSize: 15; horizontalAlignment: Text.AlignHCenter }
                background: Rectangle { color: tabBar.currentIndex === 4 ? "#1f6feb" : "#21262d"; radius: 8; border.color: tabBar.currentIndex === 4 ? "#1f6feb" : "#30363d"; border.width: 1 }
            }
        }

        StackLayout {
            id: stack
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: tabBar.currentIndex

            /* ================= Guests tab ================= */
            ColumnLayout {
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        text: "Guests on the hypervisor host"
                        color: "#e6edf3"; font.pixelSize: 14; font.bold: true
                        Layout.fillWidth: true
                    }

                    Text {
                        text: lastUpdateText
                        color: "#8b949e"; font.pixelSize: 11
                    }

                    Button {
                        text: guestsLoading ? "Refreshing..." : "Refresh"
                        implicitWidth: 110; implicitHeight: 30
                        enabled: mqtt.connected && !otaBusy
                        onClicked: { guestsLoading = true; mqtt.refreshGuests() }
                        contentItem: Text { text: parent.text; color: "#ffffff"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 12 }
                        background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 6; border.color: "#30363d"; border.width: 1 }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: "#161b22"
                    radius: 8
                    border.color: "#30363d"
                    border.width: 1
                    clip: true

                    ListView {
                        id: guestsTable
                        anchors.fill: parent
                        anchors.margins: 6
                        model: guestsModel
                        spacing: 6
                        clip: true

                        header: Rectangle {
                            width: guestsTable.width - 2
                            height: 36
                            color: "#0d1117"
                            radius: 4

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12; anchors.rightMargin: 12
                                spacing: 8

                                Text { text: "Guest";  color: "#8b949e"; font.bold: true; font.pixelSize: 14; Layout.preferredWidth: 180; Layout.minimumWidth: 180 }
                                Text { text: "Name";   color: "#8b949e"; font.bold: true; font.pixelSize: 14; Layout.preferredWidth: 170; Layout.minimumWidth: 170 }
                                Text { text: "Type";   color: "#8b949e"; font.bold: true; font.pixelSize: 14; Layout.preferredWidth: 90;  Layout.minimumWidth: 90 }
                                Text { text: "State";  color: "#8b949e"; font.bold: true; font.pixelSize: 14; Layout.preferredWidth: 90;  Layout.minimumWidth: 90 }
                                Text { text: "PID";    color: "#8b949e"; font.bold: true; font.pixelSize: 14; Layout.preferredWidth: 100; Layout.minimumWidth: 100 }
                                Text { text: "IP";     color: "#8b949e"; font.bold: true; font.pixelSize: 14; Layout.preferredWidth: 140; Layout.minimumWidth: 140 }
                                Text { text: "Actions"; color: "#8b949e"; font.bold: true; font.pixelSize: 14; Layout.preferredWidth: 260; Layout.minimumWidth: 260; horizontalAlignment: Text.AlignRight }
                            }
                        }

                        delegate: Rectangle {
                            width: guestsTable.width - 2
                            height: 64
                            radius: 6
                            color: mouseArea.containsMouse ? "#1f6feb15" : "#0d1117"
                            border.color: "#21262d"
                            border.width: 1

                            MouseArea {
                                id: mouseArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    logPanel.append("info", "Opening monitor for " + model.id + " (" + model.ip + ")...")
                                    monitorPage.setGuest(model.id, model.name, model.ip, model.running)
                                    tabBar.currentIndex = 4
                                }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12; anchors.rightMargin: 12
                                spacing: 8

                                Text { text: model.id; color: "#e6edf3"; font.pixelSize: 16; Layout.preferredWidth: 180; Layout.minimumWidth: 180; elide: Text.ElideRight }
                                Text { text: model.name; color: "#7ee787"; font.pixelSize: 16; Layout.preferredWidth: 170; Layout.minimumWidth: 170; elide: Text.ElideRight }
                                Text { text: model.type; color: "#8b949e"; font.pixelSize: 16; Layout.preferredWidth: 90;  Layout.minimumWidth: 90 }
                                Rectangle {
                                    Layout.preferredWidth: 90
                                    Layout.minimumWidth: 90
                                    Layout.preferredHeight: 28
                                    radius: 14
                                    color: model.running ? "#3fb95022" : "#8b949e22"
                                    Text {
                                        anchors.centerIn: parent
                                        text: model.state
                                        color: model.running ? "#3fb950" : "#8b949e"
                                        font.pixelSize: 14; font.bold: true
                                    }
                                }
                                Text { text: model.pid > 0 ? String(model.pid) : "-"; color: "#e6edf3"; font.pixelSize: 16; Layout.preferredWidth: 100; Layout.minimumWidth: 100 }
                                Text { text: model.ip; color: "#8b949e"; font.pixelSize: 16; Layout.preferredWidth: 140; Layout.minimumWidth: 140; elide: Text.ElideRight }

                                RowLayout {
                                    Layout.preferredWidth: 260
                                    Layout.minimumWidth: 260
                                    Layout.maximumWidth: 260
                                    spacing: 6
                                    Layout.alignment: Qt.AlignRight

                                    Button {
                                        text: "Start"
                                        implicitWidth: 74; implicitHeight: 32
                                        enabled: !model.running
                                        onClicked: { startDialog.guestId = model.id; startDialog.open() }
                                        contentItem: Text { text: parent.text; color: "#ffffff"; font.pixelSize: 13; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                        background: Rectangle { color: parent.enabled ? (parent.hovered ? "#2ea043" : "#238636") : "#21262d"; radius: 5 }
                                    }

                                    Button {
                                        text: "Kill"
                                        implicitWidth: 74; implicitHeight: 32
                                        enabled: model.running
                                        onClicked: mqtt.killGuest(model.id)
                                        contentItem: Text { text: parent.text; color: "#ffffff"; font.pixelSize: 13; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                        background: Rectangle { color: parent.enabled ? (parent.hovered ? "#da3633" : "#c22a27") : "#21262d"; radius: 5 }
                                    }

                                    Button {
                                        text: "Info"
                                        implicitWidth: 74; implicitHeight: 32
                                        onClicked: mqtt.guestInfo(model.id)
                                        contentItem: Text { text: parent.text; color: "#e6edf3"; font.pixelSize: 13; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                        background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 5; border.color: "#30363d"; border.width: 1 }
                                    }
                                }
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            text: mqtt.connected ? "(no guests found on the host)" : "Not connected — connect to see guests."
                            color: "#8b949e"; font.pixelSize: 13
                            visible: guestsModel.count === 0
                        }
                    }
                }
            }

            /* ================= OTA Update tab ================= */
            Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentHeight: otaTabCol.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                clip: true

                ColumnLayout {
                    id: otaTabCol
                    width: parent.width
                    spacing: 12

                Text {
                    text: "Update guest partitions"
                    color: "#e6edf3"; font.pixelSize: 14; font.bold: true
                }

                Text {
                    text: "Select a guest, pick a replacement file from this laptop for each partition (Change), press Upload (SCP to server), then Apply (kill guest, replace partitions, restart)."
                    color: "#8b949e"; font.pixelSize: 12
                    wrapMode: Text.Wrap
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    ComboBox {
                        id: guestPicker
                        Layout.fillWidth: true
                        model: guestComboModel
                        enabled: mqtt.connected && !otaBusy
                        background: Rectangle { color: "#0d1117"; radius: 4; border.color: "#30363d"; border.width: 1 }
                        contentItem: Text { text: guestPicker.currentText; color: "#e6edf3"; font.pixelSize: 12; leftPadding: 8; verticalAlignment: Text.AlignVCenter }
                        onCurrentIndexChanged: {
                            if (!suppressGuestRefresh) refreshPartitions()
                        }
                    }
                        Button {
                            text: "Refresh"
                            implicitHeight: 30
                            enabled: mqtt.connected && !otaBusy && selectedGuestId() !== ""
                            onClicked: refreshPartitions()
                            contentItem: Text { text: parent.text; color: "#e6edf3"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                            background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 6; border.color: "#30363d"; border.width: 1 }
                        }
                    }

                    GridLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: false
                        Layout.preferredHeight: columns === 2 ? 380 : 700
                        columns: width > 640 ? 2 : 1
                        columnSpacing: 12
                        rowSpacing: 12

                        /* Card 1: partitions on the guest */
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumWidth: 300
                            Layout.minimumHeight: 180
                            color: "#161b22"
                            radius: 8
                            border.color: "#30363d"
                            border.width: 1

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 8

                                Text {
                                    text: "Partitions on " + selectedGuestId() + (currentGuestType !== "" ? " (" + currentGuestType + ")" : "")
                                    color: "#e6edf3"; font.pixelSize: 13; font.bold: true
                                }
                                Text {
                                    text: "Press Update to pick a replacement file from this laptop."
                                    color: "#8b949e"; font.pixelSize: 11
                                    wrapMode: Text.Wrap
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 8; Layout.rightMargin: 8
                                    spacing: 8
                                    Text { text: "File"; color: "#8b949e"; font.bold: true; font.pixelSize: 11; Layout.fillWidth: true; Layout.minimumWidth: 40 }
                                    Text { text: "Size"; color: "#8b949e"; font.bold: true; font.pixelSize: 11; Layout.preferredWidth: 90; Layout.minimumWidth: 90 }
                                    Text { text: "Action"; color: "#8b949e"; font.bold: true; font.pixelSize: 11; Layout.preferredWidth: 76; Layout.minimumWidth: 76; horizontalAlignment: Text.AlignRight }
                                }

                                Flickable {
                                    id: partFlick
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    interactive: partList.count > 0
                                    flickableDirection: Flickable.VerticalFlick
                                    ScrollBar.vertical: ScrollBar { policy: partList.count > 6 ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }
                                    boundsBehavior: Flickable.StopAtBounds

                                    Column { id: partListCol; width: partFlick.width; spacing: 4 }

                                    Repeater {
                                        id: partList
                                        parent: partListCol
                                        model: partitionsModel
                                        delegate: Rectangle {
                                            width: partListCol.width - 4; height: 30; radius: 4
                                            color: mouseArea.containsMouse ? "#1f6feb15" : "#0d1117"
                                            border.color: "#21262d"; border.width: 1
                                            MouseArea { id: mouseArea; anchors.fill: parent; hoverEnabled: true }
                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: 8; anchors.rightMargin: 8
                                                spacing: 8
                                                Text { text: model.name; color: "#e6edf3"; font.pixelSize: 13; Layout.fillWidth: true; Layout.minimumWidth: 40; elide: Text.ElideMiddle }
                                                Text { text: fmtSize(model.size); color: "#8b949e"; font.pixelSize: 11; Layout.preferredWidth: 90; Layout.minimumWidth: 90 }
                                                Button {
                                                    text: "Change"
                                                    implicitWidth: 76; implicitHeight: 24
                                                    Layout.alignment: Qt.AlignRight
                                                    enabled: !otaBusy
                                                    onClicked: { pickerDest = model.name; fileDialog.pickerMode = "partition"; fileDialog.open() }
                                                    contentItem: Text { text: parent.text; color: "#ffffff"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                                    background: Rectangle { color: parent.enabled ? (parent.hovered ? "#1f6feb" : "#21262d") : "#21262d"; radius: 4; border.color: parent.enabled ? "#30363d" : "#21262d"; border.width: 1 }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        /* Card 2: staging — what will be updated */
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumWidth: 300
                            Layout.minimumHeight: 180
                            color: "#161b22"
                            radius: 8
                            border.color: "#30363d"
                            border.width: 1

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 8

                                Text {
                                    text: "Staging — will update " + stagedModel.count + " partition(s)"
                                    color: "#e6edf3"; font.pixelSize: 13; font.bold: true
                                }
                                Text {
                                    text: "Sent: " + sentCount() + " / " + stagedModel.count + "  |  Downloaded: " + readyCount() + " / " + stagedModel.count
                                    color: "#8b949e"; font.pixelSize: 11
                                    wrapMode: Text.Wrap
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 8; Layout.rightMargin: 8
                                    spacing: 8
                                    Text { text: "Partition \u2192 replacement file"; color: "#8b949e"; font.bold: true; font.pixelSize: 11; Layout.fillWidth: true }
                                    Text { text: "Remove"; color: "#8b949e"; font.bold: true; font.pixelSize: 11; Layout.preferredWidth: 24; Layout.minimumWidth: 24; horizontalAlignment: Text.AlignRight }
                                }

                                Flickable {
                                    id: stageFlick
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    interactive: stageList.count > 0
                                    flickableDirection: Flickable.VerticalFlick
                                    ScrollBar.vertical: ScrollBar { policy: stageList.count > 6 ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }
                                    boundsBehavior: Flickable.StopAtBounds

                                    Column { id: stageListCol; width: stageFlick.width; spacing: 4 }

                                    Repeater {
                                        id: stageList
                                        parent: stageListCol
                                        model: stagedModel
                                        delegate: Rectangle {
                                            property var rowModel: model
                                            width: stageListCol.width - 4
                                            height: rowModel.state === "" ? 34 : 54
                                            radius: 4
                                            color: "#0d1117"
                                            border.color: rowModel.downloaded ? "#238636" : (rowModel.sent ? "#1f6feb" : "#21262d")
                                            border.width: 1
                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.margins: 4
                                                spacing: 6
                                                ColumnLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 2
                                                    Text { text: rowModel.destName + "  \u2192  " + rowModel.local; color: "#e6edf3"; font.pixelSize: 12; elide: Text.ElideRight; Layout.fillWidth: true }
                                                    RowLayout {
                                                        visible: rowModel.state !== ""
                                                        Layout.fillWidth: true
                                                        spacing: 4
                                                        Rectangle {
                                                            Layout.preferredWidth: 62; Layout.preferredHeight: 15; radius: 3
                                                            color: fileStepColor(rowModel.state, 1)
                                                            Text { anchors.centerIn: parent; text: (fileStepDone(rowModel.state, 1) ? "\u2713 " : "") + "Upload"; color: "#0d1117"; font.pixelSize: 9; font.bold: true }
                                                        }
                                                        Rectangle {
                                                            Layout.preferredWidth: 70; Layout.preferredHeight: 15; radius: 3
                                                            color: fileStepColor(rowModel.state, 2)
                                                            Text { anchors.centerIn: parent; text: (fileStepDone(rowModel.state, 2) ? "\u2713 " : "") + "Download"; color: "#0d1117"; font.pixelSize: 9; font.bold: true }
                                                        }
                                                        Rectangle {
                                                            Layout.preferredWidth: 52; Layout.preferredHeight: 15; radius: 3
                                                            color: fileStepColor(rowModel.state, 3)
                                                            Text { anchors.centerIn: parent; text: (fileStepDone(rowModel.state, 3) ? "\u2713 " : "") + "Done"; color: "#0d1117"; font.pixelSize: 9; font.bold: true }
                                                        }
                                                        Item { Layout.fillWidth: true }
                                                    }
                                                }
                                                Button {
                                                    text: "x"
                                                    implicitWidth: 24; implicitHeight: 24
                                                    enabled: !otaBusy
                                                    onClicked: stagedModel.remove(model.index)
                                                    contentItem: Text { text: parent.text; color: "#f85149"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                                    background: Rectangle { color: parent.hovered ? "#f85149" : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
                                                }
                                            }
                                        }
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: stagedModel.count === 0
                                        ? "Nothing staged yet — press Change next to a partition."
                                        : "Upload sends to server, then downloads to the RPi — Apply installs them on the guest."
                                    color: "#8b949e"; font.pixelSize: 11
                                    wrapMode: Text.Wrap
                                }
                            }
                        }
                    }

                    /* === OTA Progress Bar === */
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 36
                            radius: 6
                            color: "#21262d"
                            clip: true
                            border.color: otaDeploying ? "#1f6feb" : "#30363d"
                            border.width: 1

                            Rectangle {
                                height: parent.height
                                width: parent.width * progressPercent / 100
                                radius: 6
                                color: chkApplied ? "#3fb950" : (chkDownloaded && !otaDeploying ? "#3fb950" : "#1f6feb")
                            }

                            Text {
                                anchors.centerIn: parent
                                text: otaDeploying || uploadingNow
                                    ? (otaStage === "download"
                                        ? "Download " + (downloadFileName !== "" ? downloadFileName : "file") + " to RPi  " + Math.round(progressPercent) + "%"
                                       : (otaStage === "pushfiles"
                                          ? "Pushing files to guest  " + Math.round(progressPercent) + "%"
                                          : (otaStage === "apply"
                                             ? "Applying on guest  " + Math.round(progressPercent) + "%"
                                          : (otaStage === "restart"
                                             ? "Restarting guest  " + Math.round(progressPercent) + "%"
                                              : "Upload " + (uploadFileName !== "" ? uploadFileName : "file") + " to server  " + Math.round(progressPercent) + "%"))))
                                    : (chkApplied ? "All files updated on guest \u2713"
                                       : (chkDownloaded ? "Downloaded to RPi — ready to Apply"
                                          : (stagedModel.count > 0 ? "Files staged, press Upload to send"
                                             : "Select a file and press Upload")))
                                color: "#e6edf3"
                                font.pixelSize: 12; font.bold: true
                            }
                        }

                        Text {
                            id: otaStageLabel
                            Layout.fillWidth: true
                            text: "Select a guest, then press Update for the partitions you want to replace."
                            color: "#8b949e"; font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Button {
                            text: uploadingNow ? "Uploading..." : "Upload (Send via SCP)"
                            implicitWidth: 170; implicitHeight: 34
                            enabled: mqtt.connected && !otaBusy && (stagedModel.count > sentCount() || sentCount() > readyCount())
                            onClicked: sendAll()
                            contentItem: Text { text: parent.text; color: "#ffffff"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                            background: Rectangle { color: parent.enabled ? (parent.hovered ? "#1f6feb" : "#21262d") : "#21262d"; radius: 6; border.color: "#30363d"; border.width: 1 }
                        }
                        Button {
                            text: "Apply (kill + replace + restart)"
                            implicitWidth: 230; implicitHeight: 34
                            enabled: mqtt.connected && chkDownloaded
                            onClicked: doApply()
                            contentItem: Text { text: parent.text; color: "#ffffff"; font.bold: true; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                            background: Rectangle { color: parent.enabled ? (parent.hovered ? "#2ea043" : "#238636") : "#21262d"; radius: 6 }
                        }
                        Item { Layout.fillWidth: true }
                    }

                    /* === Send files to guest === */
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.minimumHeight: 210
                        color: "#161b22"
                        radius: 8
                        border.color: "#30363d"
                        border.width: 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 8

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Text {
                                    text: "Send files to guest — each file is placed at its path in the guest filesystem"
                                    color: "#e6edf3"; font.pixelSize: 13; font.bold: true
                                    Layout.fillWidth: true; wrapMode: Text.Wrap
                                }
                                Button {
                                    text: "Add file"
                                    implicitWidth: 110; implicitHeight: 30
                                    enabled: mqtt.connected && !otaBusy && selectedGuestId() !== ""
                                    onClicked: { pickerDest = ""; fileDialog.pickerMode = "send"; fileDialog.open() }
                                    contentItem: Text { text: parent.text; color: "#ffffff"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                    background: Rectangle { color: parent.enabled ? (parent.hovered ? "#1f6feb" : "#21262d") : "#21262d"; radius: 6; border.color: "#30363d"; border.width: 1 }
                                }
                                Button {
                                    text: pushingNow ? "Sending..." : "Send to guest"
                                    implicitWidth: 150; implicitHeight: 30
                                    enabled: mqtt.connected && !otaBusy && sendModel.count > 0 && allSendDestSet() && selectedGuestId() !== ""
                                    onClicked: sendFilesToGuest()
                                    contentItem: Text { text: parent.text; color: "#ffffff"; font.bold: true; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                    background: Rectangle { color: parent.enabled ? (parent.hovered ? "#2ea043" : "#238636") : "#21262d"; radius: 6 }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                text: pushStatus !== ""
                                    ? pushStatus
                                    : (sendModel.count === 0 ? "Add files, set their destination in the guest, then Send."
                                                             : "Pack: " + sendModel.count + " file(s). Use Browse to pick the guest path, or type it.")
                                color: "#8b949e"; font.pixelSize: 11
                                wrapMode: Text.Wrap
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.leftMargin: 8; Layout.rightMargin: 8
                                spacing: 8
                                Text { text: "File \u2192 destination in guest"; color: "#8b949e"; font.bold: true; font.pixelSize: 11; Layout.fillWidth: true }
                                Text { text: "Remove"; color: "#8b949e"; font.bold: true; font.pixelSize: 11; Layout.preferredWidth: 24; Layout.minimumWidth: 24; horizontalAlignment: Text.AlignRight }
                            }

                            Flickable {
                                id: sendFlick
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                interactive: sendList.count > 0
                                flickableDirection: Flickable.VerticalFlick
                                ScrollBar.vertical: ScrollBar { policy: sendList.count > 4 ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }
                                boundsBehavior: Flickable.StopAtBounds

                                Column { id: sendListCol; width: sendFlick.width; spacing: 4 }

                                Repeater {
                                    id: sendList
                                    parent: sendListCol
                                    model: sendModel
                                    delegate: Rectangle {
                                        width: sendListCol.width - 4; height: 34; radius: 4
                                        color: "#0d1117"
                                        border.color: "#21262d"; border.width: 1
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.margins: 4
                                            spacing: 6
                                            Text { text: model.local; color: "#e6edf3"; font.pixelSize: 12; elide: Text.ElideLeft; Layout.fillWidth: true; Layout.minimumWidth: 40 }
                                            TextField {
                                                Layout.preferredWidth: 260
                                                text: model.dest
                                                color: "#e6edf3"
                                                placeholderText: "/path/in/guest"
                                                placeholderTextColor: "#8b949e"
                                                font.pixelSize: 11
                                                leftPadding: 6
                                                verticalAlignment: Text.AlignVCenter
                                                selectByMouse: true
                                                background: Rectangle { color: "#161b22"; radius: 4; border.color: "#30363d"; border.width: 1 }
                                                onEditingFinished: {
                                                    var d = text.trim()
                                                    if (d !== "" && d[0] !== "/") d = "/" + d
                                                    sendModel.set(model.index, { local: model.local, dest: d })
                                                }
                                            }
                                            Button {
                                                text: "Browse"
                                                implicitWidth: 76; implicitHeight: 24
                                                enabled: mqtt.connected && !otaBusy && selectedGuestId() !== ""
                                                onClicked: { browseRow = model.index; guestBrowser.open() }
                                                contentItem: Text { text: parent.text; color: "#ffffff"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                                background: Rectangle { color: parent.enabled ? (parent.hovered ? "#1f6feb" : "#21262d") : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
                                            }
                                            Button {
                                                text: "x"
                                                implicitWidth: 24; implicitHeight: 24
                                                enabled: !otaBusy
                                                onClicked: sendModel.remove(model.index)
                                                contentItem: Text { text: parent.text; color: "#f85149"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                                background: Rectangle { color: parent.hovered ? "#f85149" : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
            }
            }

            /* ================= Remote Shell tab ================= */
            ColumnLayout {
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    ComboBox {
                        id: shellGuestPicker
                        Layout.preferredWidth: 260
                        model: guestComboModel
                        background: Rectangle { color: "#0d1117"; radius: 4; border.color: "#30363d"; border.width: 1 }
                        contentItem: Text { text: shellGuestPicker.currentText; color: "#e6edf3"; font.pixelSize: 12; leftPadding: 8; verticalAlignment: Text.AlignVCenter }
                    }

                    TextField {
                        id: shellCmdInput
                        Layout.fillWidth: true
                        placeholderText: "Command to run on the guest (via SSH), e.g. uname -a"
                        color: "#e6edf3"
                        placeholderTextColor: "#8b949e"
                        background: Rectangle { color: "#0d1117"; radius: 4; border.color: "#30363d"; border.width: 1 }
                        onAccepted: runShellBtn.clicked()
                    }

                    Button {
                        id: runShellBtn
                        text: "Run"
                        implicitWidth: 90; implicitHeight: 30
                        enabled: mqtt.connected && guestsModel.count > 0
                        onClicked: {
                            if (shellCmdInput.text.trim() !== "")
                                mqtt.execCommand(guestsModel.get(shellGuestPicker.currentIndex).id, shellCmdInput.text.trim())
                        }
                        contentItem: Text { text: parent.text; color: "#ffffff"; font.bold: true; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.enabled ? (parent.hovered ? "#2ea043" : "#238636") : "#21262d"; radius: 6 }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: false
                    Layout.preferredHeight: 96
                    color: "#161b22"
                    radius: 8
                    border.color: "#30363d"
                    border.width: 1
                    clip: true

                    Flickable {
                        id: shellOutputFlick
                        anchors.fill: parent
                        anchors.margins: 10
                        contentWidth: shellOutput.width
                        contentHeight: shellOutput.height

                        Text {
                            id: shellOutput
                            text: "(no output yet)"
                            color: "#e6edf3"
                            font.family: "monospace"
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }

            /* ================= Log tab ================= */
            LogPanel {
                id: logPanel
                Layout.fillWidth: true
                Layout.fillHeight: true
            }

            /* ================= Monitor tab ================= */
            GuestMonitor {
                id: monitorPage
                Layout.fillWidth: true
                Layout.fillHeight: true
                enabled: tabBar.currentIndex === 4 && mqtt.connected
                onRequestStats: (id) => mqtt.guestStats(id)
                onBackRequested: tabBar.currentIndex = 0
            }
        }
    }

    Connections {
        target: mqtt
        function onGuestStatsReceived(json) { monitorPage.onStats(json) }
    }

    Component.onCompleted: {
        logPanel.append("info", "OTA Update GUI started. Connecting to broker...")
        mqtt.connectToBroker()
    }
}
