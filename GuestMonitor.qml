import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "StatsParser.js" as Stats

Item {
    id: root
    Layout.fillWidth: true
    Layout.fillHeight: true

    /* Set by main.qml: true while this tab is visible and MQTT is connected. */
    property bool enabled: false
    property bool autoRefresh: true
    property int pollIntervalMs: 3000

    property string guestId: ""
    property string guestName: ""
    property string guestIp: ""
    property bool guestRunning: false
    property string lastUpdated: ""
    property string statusText: ""
    property bool requestInFlight: false

    signal requestStats(string id)
    signal backRequested()

    ListModel { id: hostProcs }
    ListModel { id: guestProcs }

    property var hostSnap: null
    property var guestSnap: null
    property var hostSummary: null
    property var guestSummary: null
    property var hostView: []
    property var guestView: []

    function fillModel(model, view) {
        model.clear()
        for (var i = 0; i < view.length; i++) {
            var p = view[i]
            model.append({
                pid: p.pid,
                name: p.name,
                cpu: (p.cpu === null) ? -1 : p.cpu,
                mem: (p.mem === null) ? -1 : p.mem
            })
        }
    }

    function setGuest(id, name, ip, running) {
        /* A fresh click always triggers a fresh request — never silently
           skip it because of stale in-flight state. */
        requestInFlight = false
        watchdog.stop()
        guestId = id
        guestName = name || ""
        guestIp = ip || ""
        guestRunning = running
        guestSnap = null
        guestSummary = null
        guestView = []
        guestProcs.clear()
        statusText = ""
        if (enabled)
            refreshNow()
    }

    function onStats(json) {
        try {
            var obj = JSON.parse(json)
        } catch (e) {
            requestInFlight = false
            watchdog.stop()
            statusText = "Parse error: " + e.message
            return
        }
        requestInFlight = false
        watchdog.stop()

        /* Ignore responses for a guest that is no longer selected. */
        if (obj.guest_id && obj.guest_id !== "" && obj.guest_id !== guestId)
            return

        lastUpdated = new Date().toLocaleTimeString(Qt.locale("en_US"), "hh:mm:ss")
        statusText = ""

        try {
            var h = Stats.parseSnapshot(obj.host)
            hostSummary = h
            var prevH = hostSnap
            hostSnap = h
            hostView = Stats.buildView(h, prevH, pollIntervalMs)
            fillModel(hostProcs, hostView)

            guestRunning = (obj.guest_running === true)
            if (guestRunning && obj.guest && obj.guest !== "") {
                var g = Stats.parseSnapshot(obj.guest)
                guestSummary = g
                var prevG = guestSnap
                guestSnap = g
                guestView = Stats.buildView(g, prevG, pollIntervalMs)
                fillModel(guestProcs, guestView)
            } else {
                guestSnap = null
                guestSummary = null
                guestView = []
                guestProcs.clear()
            }
        } catch (e) {
            statusText = "Parse error: " + e.message
        }
    }

    function refreshNow() {
        if (requestInFlight)
            return
        requestInFlight = true
        statusText = "Fetching..."
        watchdog.start()
        requestStats(guestId)
    }

    /* ============================ Small building blocks ============================ */

    component Card: Rectangle {
        property string label: ""
        property string value: ""
        implicitWidth: 200
        implicitHeight: labelText.implicitHeight + valueText.implicitHeight + 24
        radius: 6
        color: "#0d1117"
        border.color: "#21262d"
        border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 3

            Text {
                id: labelText
                text: label
                color: "#8b949e"
                font.pixelSize: 11
                Layout.fillWidth: true
            }
            Text {
                id: valueText
                text: value
                color: "#e6edf3"
                font.pixelSize: 14
                font.bold: true
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                verticalAlignment: Text.AlignTop
            }
        }
    }

    component RamCard: Rectangle {
        property string label: ""
        property string usedText: ""
        property string totalText: ""
        property real usedBytes: 0
        property real totalBytes: 0
        implicitWidth: 300
        implicitHeight: 58
        radius: 6
        color: "#0d1117"
        border.color: "#21262d"
        border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 4

            Text {
                text: label
                color: "#8b949e"
                font.pixelSize: 11
            }
            Text {
                text: usedText + " / " + totalText
                color: "#e6edf3"
                font.pixelSize: 14
                font.bold: true
            }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 6
                radius: 3
                color: "#21262d"
                clip: true

                Rectangle {
                    height: parent.height
                    width: (totalBytes > 0) ? parent.width * Math.min(usedBytes / totalBytes, 1) : 0
                    radius: 3
                    color: (totalBytes > 0 && usedBytes / totalBytes > 0.9) ? "#da3633"
                         : (totalBytes > 0 && usedBytes / totalBytes > 0.7) ? "#d29922" : "#238636"
                }
            }
        }
    }

    component ProcTable: ColumnLayout {
        property ListModel procModel
        property string emptyText: "(no data yet)"

        spacing: 6

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 34
            radius: 4
            color: "#0d1117"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12; anchors.rightMargin: 12
                spacing: 8

                Text { text: "PID";   color: "#8b949e"; font.bold: true; font.pixelSize: 13; Layout.preferredWidth: 90;  Layout.minimumWidth: 90 }
                Text { text: "CPU%";  color: "#8b949e"; font.bold: true; font.pixelSize: 13; Layout.preferredWidth: 100; Layout.minimumWidth: 100 }
                Text { text: "MEM";   color: "#8b949e"; font.bold: true; font.pixelSize: 13; Layout.preferredWidth: 100; Layout.minimumWidth: 100 }
                Text { text: "Name";  color: "#8b949e"; font.bold: true; font.pixelSize: 13; Layout.fillWidth: true }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: 4
            color: "#0d1117"

            ListView {
                id: procList
                anchors.fill: parent
                anchors.margins: 4
                model: procModel
                spacing: 2
                clip: true

                delegate: RowLayout {
                    width: procList.width - 8
                    implicitHeight: 30
                    spacing: 8

                    Text { text: String(model.pid); color: "#e6edf3"; font.pixelSize: 13; Layout.preferredWidth: 90;  Layout.minimumWidth: 90 }
                    Text {
                        text: (model.cpu < 0) ? "\u2013" : model.cpu.toFixed(1)
                        color: (model.cpu < 0) ? "#8b949e" : (model.cpu > 50 ? "#da3633" : model.cpu > 10 ? "#d29922" : "#7ee787")
                        font.pixelSize: 13; font.bold: true
                        Layout.preferredWidth: 100; Layout.minimumWidth: 100
                    }
                    Text { text: (model.mem < 0) ? "\u2013" : Stats.fmtBytes(model.mem); color: "#8b949e"; font.pixelSize: 13; Layout.preferredWidth: 100; Layout.minimumWidth: 100 }
                    Text { text: model.name; color: "#e6edf3"; font.pixelSize: 13; Layout.fillWidth: true; elide: Text.ElideRight }
                }

                Text {
                    anchors.centerIn: parent
                    text: emptyText
                    color: "#8b949e"
                    font.pixelSize: 12
                    visible: procModel.count === 0
                }
            }
        }
    }

    /* ============================ Page layout ============================ */

    ColumnLayout {
        anchors.fill: parent
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Button {
                text: "\u2190 Back"
                implicitWidth: 90; implicitHeight: 32
                onClicked: root.backRequested()
                contentItem: Text { text: parent.text; color: "#e6edf3"; font.bold: true; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 6; border.color: "#30363d"; border.width: 1 }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }

            Text {
                text: root.lastUpdated !== "" ? "Updated " + root.lastUpdated : ""
                color: "#8b949e"; font.pixelSize: 11
            }

            Button {
                text: root.autoRefresh ? "Auto: ON" : "Auto: OFF"
                implicitWidth: 90; implicitHeight: 32
                onClicked: root.autoRefresh = !root.autoRefresh
                contentItem: Text { text: parent.text; color: root.autoRefresh ? "#7ee787" : "#8b949e"; font.bold: true; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 6; border.color: "#30363d"; border.width: 1 }
            }

            Button {
                text: root.statusText !== "" ? root.statusText : "Refresh"
                implicitWidth: 100; implicitHeight: 32
                enabled: root.enabled
                onClicked: root.refreshNow()
                contentItem: Text { text: parent.text; color: "#ffffff"; font.bold: true; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: parent.enabled ? (parent.hovered ? "#2ea043" : "#238636") : "#21262d"; radius: 6 }
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

            ScrollView {
                anchors.fill: parent
                anchors.margins: 10
                clip: true

                contentItem: Flickable {
                    id: scrollFlick
                    contentWidth: scrollCol.width
                    contentHeight: scrollCol.height

                    ColumnLayout {
                        id: scrollCol
                        width: scrollFlick.width
                        spacing: 14

                    /* ---------- Host section ---------- */
                    Text {
                        text: "Hypervisor Host"
                        color: "#e6edf3"; font.pixelSize: 13; font.bold: true
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Card { label: "Hostname"; value: root.hostSummary ? (root.hostSummary.hostname || "\u2013") : "\u2013" }
                        Card {
                            label: "Load"
                            value: (root.hostSummary && root.hostSummary.load.length > 0)
                                ? root.hostSummary.load.map(function (v) { return v.toFixed(2) }).join(" / ")
                                : (root.hostSummary && root.hostSummary.cpuBusyPct !== null)
                                    ? "busy " + root.hostSummary.cpuBusyPct.toFixed(0) + "%"
                                    : "\u2013"
                        }
                        Card {
                            label: "CPU(s)"
                            value: root.hostSummary && root.hostSummary.cpus > 0
                                ? String(root.hostSummary.cpus) + (root.hostSummary.threads > 0 ? " \u00b7 " + root.hostSummary.threads + " threads" : "")
                                : "\u2013"
                        }
                        Card {
                            label: "Kernel"
                            Layout.preferredWidth: 280
                            value: root.hostSummary ? (root.hostSummary.kernel || "\u2013") : "\u2013"
                        }
                        RamCard {
                            label: "RAM"
                            usedText: (root.hostSummary && root.hostSummary.ram.used !== null) ? Stats.fmtBytes(root.hostSummary.ram.used) : "\u2013"
                            totalText: (root.hostSummary && root.hostSummary.ram.total !== null) ? Stats.fmtBytes(root.hostSummary.ram.total) : "\u2013"
                            usedBytes: (root.hostSummary && root.hostSummary.ram.used) ? root.hostSummary.ram.used : 0
                            totalBytes: (root.hostSummary && root.hostSummary.ram.total) ? root.hostSummary.ram.total : 0
                        }
                    }

                    ProcTable {
                        id: hostProcTable
                        Layout.fillWidth: true
                        Layout.preferredHeight: 200
                        procModel: hostProcs
                        emptyText: "(host process data will appear on the next poll)"
                    }

                    /* ---------- Guest section ---------- */
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Text {
                            text: root.guestId !== ""
                                ? "Guest \u2014 " + root.guestId + (root.guestName !== "" && root.guestName !== "-" ? " \u00b7 " + root.guestName : "")
                                : "Guest"
                            color: "#e6edf3"; font.pixelSize: 13; font.bold: true
                            Layout.fillWidth: true
                        }

                        Rectangle {
                            implicitWidth: 90
                            implicitHeight: 24
                            radius: 12
                            color: root.guestRunning ? "#3fb95022" : "#f8514922"
                            visible: root.guestId !== ""
                            Text {
                                anchors.centerIn: parent
                                text: root.guestRunning ? "running" : "stopped"
                                color: root.guestRunning ? "#3fb950" : "#f85149"
                                font.pixelSize: 12; font.bold: true
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: root.guestId === ""
                        text: "Select a guest from the Guests tab to monitor it here as well."
                        color: "#8b949e"; font.pixelSize: 12
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: root.guestId !== "" && !root.guestRunning
                        text: "Guest is not running \u2014 process statistics unavailable."
                        color: "#f85149"; font.pixelSize: 12
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        visible: root.guestId !== "" && root.guestRunning
                        spacing: 8

                        Card { label: "Hostname"; value: root.guestSummary ? (root.guestSummary.hostname || "\u2013") : "\u2013" }
                        Card {
                            label: "Load"
                            value: (root.guestSummary && root.guestSummary.load.length > 0)
                                ? root.guestSummary.load.map(function (v) { return v.toFixed(2) }).join(" / ")
                                : (root.guestSummary && root.guestSummary.cpuBusyPct !== null)
                                    ? "busy " + root.guestSummary.cpuBusyPct.toFixed(0) + "%"
                                    : "\u2013"
                        }
                        Card {
                            label: "CPU(s)"
                            value: root.guestSummary && root.guestSummary.cpus > 0
                                ? String(root.guestSummary.cpus) + (root.guestSummary.threads > 0 ? " \u00b7 " + root.guestSummary.threads + " threads" : "")
                                : "\u2013"
                        }
                        Card {
                            label: "Kernel"
                            Layout.preferredWidth: 280
                            value: root.guestSummary ? (root.guestSummary.kernel || "\u2013") : "\u2013"
                        }
                        RamCard {
                            label: "RAM"
                            usedText: (root.guestSummary && root.guestSummary.ram.used !== null) ? Stats.fmtBytes(root.guestSummary.ram.used) : "\u2013"
                            totalText: (root.guestSummary && root.guestSummary.ram.total !== null) ? Stats.fmtBytes(root.guestSummary.ram.total) : "\u2013"
                            usedBytes: (root.guestSummary && root.guestSummary.ram.used) ? root.guestSummary.ram.used : 0
                            totalBytes: (root.guestSummary && root.guestSummary.ram.total) ? root.guestSummary.ram.total : 0
                        }
                    }

                    ProcTable {
                        id: guestProcTable
                        Layout.fillWidth: true
                        Layout.preferredHeight: 200
                        Layout.bottomMargin: 10
                        procModel: guestProcs
                        emptyText: "(guest process data will appear on the next poll)"
                    }
                }
            }
        }
    }
    }

    Timer {
        id: pollTimer
        interval: root.pollIntervalMs
        repeat: true
        running: root.enabled && root.autoRefresh
        onTriggered: {
            /* Skip a poll while the previous stats request is still in flight —
               each request takes a few seconds (SSH into the guest), so sending
               every 3 s regardless would backlog HMS. */
            if (!root.requestInFlight) {
                root.requestInFlight = true
                watchdog.start()
                root.requestStats(root.guestId)
            }
        }
    }

    /* If no stats response arrives (HMS busy / connection hiccup), release the
       in-flight flag after 15 s so polling can resume. */
    Timer {
        id: watchdog
        interval: 15000
        repeat: false
        onTriggered: {
            root.requestInFlight = false
            root.statusText = "No response \u2014 will retry"
        }
    }

    onEnabledChanged: {
        if (enabled) {
            statusText = "Fetching..."
            refreshNow()
        } else {
            requestInFlight = false
            watchdog.stop()
        }
    }
}
