import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import App 1.0
import "StatsParser.js" as Stats

/*
 * Live host and guest statistics.
 *
 * Same parsing as before (StatsParser.js is untouched), restyled onto the
 * shared theme with larger type. Two changes beyond looks:
 *
 *  - `enabled` is no longer redeclared. Item already has an `enabled` property
 *    and shadowing it meant "this tab is visible" and "this item accepts input"
 *    were the same flag, so the page's own controls went dead whenever polling
 *    was meant to stop. It is `active` now.
 *  - The stat cards use a Flow, so they wrap instead of being squeezed to
 *    illegibility on a narrow window.
 */
Item {
    id: root

    property bool active: false
    property bool autoRefresh: true
    /* 5s, not 3s. Each poll parses a few hundred lines of `top`/`pidin` output
       in JS on the GUI thread and then refills two list models, so the interval
       is a direct tax on how responsive the whole app feels. */
    property int  pollIntervalMs: 5000

    /* Only the busiest processes are worth showing, and the cost of the refill
       is proportional to how many rows there are. A QNX host reports hundreds;
       the view is sorted by CPU descending, so the tail is all idle. */
    property int  maxRows: 60

    property string guestId: ""
    property string guestName: ""
    property string guestIp: ""
    property bool   guestRunning: false
    property string guestError: ""
    property string lastUpdated: ""
    property string statusText: ""
    property bool   requestInFlight: false

    signal requestStats(string id)

    ListModel { id: hostProcs }
    ListModel { id: guestProcs }

    property var hostSnap: null
    property var guestSnap: null
    property var hostSummary: null
    property var guestSummary: null

    /*
     * Update in place rather than clear-and-refill.
     *
     * model.clear() followed by append() per row makes the ListView discard and
     * rebuild every delegate, twice, every poll -- which is what the periodic
     * hitch was. Setting existing rows leaves the delegates alone.
     */
    function fillModel(model, view) {
        var n = Math.min(view.length, maxRows)
        for (var i = 0; i < n; i++) {
            var p = view[i]
            var row = {
                pid: p.pid,
                name: p.name,
                cpu: (p.cpu === null) ? -1 : p.cpu,
                mem: (p.mem === null) ? -1 : p.mem
            }
            if (i < model.count) model.set(i, row)
            else                 model.append(row)
        }
        while (model.count > n)
            model.remove(model.count - 1)
    }

    function setGuest(id, name, ip, running) {
        requestInFlight = false
        watchdog.stop()
        guestId = id
        guestName = name || ""
        guestIp = ip || ""
        guestRunning = running
        guestSnap = null
        guestSummary = null
        guestProcs.clear()
        statusText = ""
        if (active) refreshNow()
    }

    function onStats(json) {
        var obj
        try {
            obj = JSON.parse(json)
        } catch (e) {
            requestInFlight = false
            watchdog.stop()
            statusText = "Parse error: " + e.message
            return
        }
        requestInFlight = false
        watchdog.stop()

        if (obj.guest_id && obj.guest_id !== "" && obj.guest_id !== guestId)
            return

        lastUpdated = Qt.formatTime(new Date(), "hh:mm:ss")
        statusText = ""

        try {
            var h = Stats.parseSnapshot(obj.host)
            hostSummary = h
            var prevH = hostSnap
            hostSnap = h
            fillModel(hostProcs, Stats.buildView(h, prevH, pollIntervalMs))

            guestRunning = (obj.guest_running === true)
            /* HMS now says why the guest half is missing instead of just
               omitting it, which used to be indistinguishable from the guest
               being stopped. */
            guestError = obj.guest_error || ""
            if (guestRunning && obj.guest && obj.guest !== "") {
                var g = Stats.parseSnapshot(obj.guest)
                guestSummary = g
                var prevG = guestSnap
                guestSnap = g
                fillModel(guestProcs, Stats.buildView(g, prevG, pollIntervalMs))
            } else {
                guestSnap = null
                guestSummary = null
                guestProcs.clear()
            }
        } catch (e2) {
            statusText = "Parse error: " + e2.message
        }
    }

    function refreshNow() {
        if (requestInFlight) return
        requestInFlight = true
        statusText = "Fetching…"
        watchdog.start()
        requestStats(guestId)
    }

    function loadText(s) {
        if (!s) return "—"
        if (s.load && s.load.length > 0)
            return s.load.map(function (v) { return v.toFixed(2) }).join("  ")
        if (s.cpuBusyPct !== null && s.cpuBusyPct !== undefined)
            return "busy " + s.cpuBusyPct.toFixed(0) + "%"
        return "—"
    }

    /* ---------------- building blocks ---------------- */

    component Stat: Rectangle {
        property string label: ""
        property string value: ""
        property int minWidth: 170

        implicitWidth: Math.max(minWidth, valueText.implicitWidth + 28)
        implicitHeight: 74
        radius: Theme.radiusSmall
        color: Theme.surfaceSunken
        border.color: Theme.outline
        border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 4

            Text {
                text: label
                color: Theme.textSecondary
                font.pixelSize: Theme.fontTiny
                font.weight: Font.DemiBold
            }
            Text {
                id: valueText
                text: value
                color: Theme.textPrimary
                font.pixelSize: Theme.fontMedium
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
    }

    component RamStat: Rectangle {
        property string label: "RAM"
        property real usedBytes: 0
        property real totalBytes: 0

        readonly property real frac: totalBytes > 0
            ? Math.min(usedBytes / totalBytes, 1) : 0

        implicitWidth: 260
        implicitHeight: 74
        radius: Theme.radiusSmall
        color: Theme.surfaceSunken
        border.color: Theme.outline
        border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 4

            Text {
                text: label
                color: Theme.textSecondary
                font.pixelSize: Theme.fontTiny
                font.weight: Font.DemiBold
            }
            Text {
                text: totalBytes > 0
                    ? Stats.fmtBytes(usedBytes) + " / " + Stats.fmtBytes(totalBytes)
                    : "—"
                color: Theme.textPrimary
                font.pixelSize: Theme.fontMedium
                font.weight: Font.DemiBold
            }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 6
                radius: 3
                color: Theme.surfaceVariant

                Rectangle {
                    width: parent.width * frac
                    height: parent.height
                    radius: 3
                    color: frac > 0.9 ? Theme.danger
                         : frac > 0.7 ? Theme.warning : Theme.success
                    Behavior on width { NumberAnimation { duration: 220 } }
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
            implicitHeight: Theme.headerHeight
            radius: Theme.radiusSmall
            color: Theme.surfaceVariant

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.spacing
                anchors.rightMargin: Theme.spacing
                spacing: Theme.spacingTight

                Text { text: "PID";  color: Theme.textSecondary; font.pixelSize: Theme.fontTiny; font.weight: Font.DemiBold; Layout.preferredWidth: 90 }
                Text { text: "CPU%"; color: Theme.textSecondary; font.pixelSize: Theme.fontTiny; font.weight: Font.DemiBold; Layout.preferredWidth: 90 }
                Text { text: "MEM";  color: Theme.textSecondary; font.pixelSize: Theme.fontTiny; font.weight: Font.DemiBold; Layout.preferredWidth: 110 }
                Text { text: "PROCESS"; color: Theme.textSecondary; font.pixelSize: Theme.fontTiny; font.weight: Font.DemiBold; Layout.fillWidth: true }
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
                id: procList
                anchors.fill: parent
                anchors.margins: 6
                model: procModel
                spacing: 1
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Item {
                    width: procList.width - 8
                    height: 32

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingTight
                        anchors.rightMargin: Theme.spacingTight
                        spacing: Theme.spacingTight

                        Text {
                            text: String(model.pid)
                            color: Theme.textSecondary
                            font.family: Theme.monoFamily
                            font.pixelSize: Theme.fontSmall
                            Layout.preferredWidth: 90
                        }
                        Text {
                            text: (model.cpu < 0) ? "—" : model.cpu.toFixed(1)
                            color: (model.cpu < 0) ? Theme.textDisabled
                                 : model.cpu > 50 ? Theme.danger
                                 : model.cpu > 10 ? Theme.warning : Theme.success
                            font.family: Theme.monoFamily
                            font.pixelSize: Theme.fontSmall
                            font.weight: Font.DemiBold
                            Layout.preferredWidth: 90
                        }
                        Text {
                            text: (model.mem < 0) ? "—" : Stats.fmtBytes(model.mem)
                            color: Theme.textSecondary
                            font.family: Theme.monoFamily
                            font.pixelSize: Theme.fontSmall
                            Layout.preferredWidth: 110
                        }
                        Text {
                            text: model.name
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontSmall
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    text: emptyText
                    color: Theme.textDisabled
                    font.pixelSize: Theme.fontBody
                    visible: procModel.count === 0
                }
            }
        }
    }

    /* ---------------- page ---------------- */

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingTight

            SectionTitle {
                Layout.fillWidth: true
                title: "System monitor"
                subtitle: root.guestId !== ""
                    ? "Hypervisor host and guest " + root.guestId +
                      (root.guestIp !== "" && root.guestIp !== "-" ? " (" + root.guestIp + ")" : "")
                    : "Hypervisor host only — pick a guest from the Guests page to add it."
            }

            Text {
                text: root.lastUpdated !== "" ? "Updated " + root.lastUpdated : ""
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSmall
                Layout.alignment: Qt.AlignVCenter
            }

            Switch {
                text: "Auto"
                checked: root.autoRefresh
                font.pixelSize: Theme.fontBody
                Material.foreground: Theme.textPrimary
                Material.accent: Theme.primary
                onToggled: root.autoRefresh = checked
            }

            FilledButton {
                text: root.statusText !== "" ? root.statusText : "Refresh"
                implicitHeight: Theme.controlHeight
                implicitWidth: 130
                font.pixelSize: Theme.fontBody
                enabled: root.active && !root.requestInFlight
                accent: Theme.primary
                onClicked: root.refreshNow()
            }
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: root.width
                spacing: Theme.spacing

                /* ---- host ---- */
                AppCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 400

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: Theme.spacingTight

                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: "Hypervisor host"
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontMedium
                                font.weight: Font.DemiBold
                                Layout.fillWidth: true
                            }
                            StatusPill { text: "online"; tone: "success" }
                        }

                        Flow {
                            Layout.fillWidth: true
                            spacing: Theme.spacingTight

                            Stat { label: "HOSTNAME"; value: root.hostSummary ? (root.hostSummary.hostname || "—") : "—" }
                            Stat { label: "LOAD";     value: root.loadText(root.hostSummary) }
                            Stat {
                                label: "CPUS"
                                value: root.hostSummary && root.hostSummary.cpus > 0
                                    ? String(root.hostSummary.cpus) +
                                      (root.hostSummary.threads > 0 ? " · " + root.hostSummary.threads + " threads" : "")
                                    : "—"
                            }
                            RamStat {
                                usedBytes: (root.hostSummary && root.hostSummary.ram.used) ? root.hostSummary.ram.used : 0
                                totalBytes: (root.hostSummary && root.hostSummary.ram.total) ? root.hostSummary.ram.total : 0
                            }
                            Stat {
                                label: "KERNEL"
                                minWidth: 320
                                value: root.hostSummary ? (root.hostSummary.kernel || "—") : "—"
                            }
                        }

                        ProcTable {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            procModel: hostProcs
                            emptyText: "Host process data appears on the next poll."
                        }
                    }
                }

                /* ---- guest ---- */
                AppCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.guestRunning ? 400 : 140

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: Theme.spacingTight

                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: root.guestId !== ""
                                    ? "Guest — " + root.guestId +
                                      (root.guestName !== "" && root.guestName !== "-" ? " · " + root.guestName : "")
                                    : "Guest"
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontMedium
                                font.weight: Font.DemiBold
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                            StatusPill {
                                visible: root.guestId !== ""
                                text: root.guestRunning ? "running" : "stopped"
                                tone: root.guestRunning ? "success" : "danger"
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: root.guestId === ""
                            text: "No guest selected. Click a row on the Guests page to monitor it alongside the host."
                            color: Theme.textSecondary
                            font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: root.guestId !== "" && !root.guestRunning
                            spacing: 4

                            Text {
                                Layout.fillWidth: true
                                text: root.guestError !== ""
                                    ? "No statistics for this guest — HMS could not reach it over SSH."
                                    : "Guest is not running — nothing to report."
                                color: Theme.warning
                                font.pixelSize: Theme.fontBody
                                wrapMode: Text.Wrap
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: root.guestError !== ""
                                text: root.guestError
                                color: Theme.textSecondary
                                font.family: Theme.monoFamily
                                font.pixelSize: Theme.fontSmall
                                wrapMode: Text.WrapAnywhere
                            }
                        }

                        Flow {
                            Layout.fillWidth: true
                            visible: root.guestRunning
                            spacing: Theme.spacingTight

                            Stat { label: "HOSTNAME"; value: root.guestSummary ? (root.guestSummary.hostname || "—") : "—" }
                            Stat { label: "LOAD";     value: root.loadText(root.guestSummary) }
                            Stat {
                                label: "CPUS"
                                value: root.guestSummary && root.guestSummary.cpus > 0
                                    ? String(root.guestSummary.cpus) +
                                      (root.guestSummary.threads > 0 ? " · " + root.guestSummary.threads + " threads" : "")
                                    : "—"
                            }
                            RamStat {
                                usedBytes: (root.guestSummary && root.guestSummary.ram.used) ? root.guestSummary.ram.used : 0
                                totalBytes: (root.guestSummary && root.guestSummary.ram.total) ? root.guestSummary.ram.total : 0
                            }
                            Stat {
                                label: "KERNEL"
                                minWidth: 320
                                value: root.guestSummary ? (root.guestSummary.kernel || "—") : "—"
                            }
                        }

                        ProcTable {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.guestRunning
                            procModel: guestProcs
                            emptyText: "Guest process data appears on the next poll."
                        }
                    }
                }

                Item { Layout.preferredHeight: Theme.spacing }
            }
        }
    }

    Timer {
        id: pollTimer
        interval: root.pollIntervalMs
        repeat: true
        running: root.active && root.autoRefresh
        onTriggered: {
            /* Skip while a request is outstanding: each one SSHes into the
               guest and can take seconds, so polling regardless would backlog
               HMS. */
            if (!root.requestInFlight) {
                root.requestInFlight = true
                watchdog.start()
                root.requestStats(root.guestId)
            }
        }
    }

    Timer {
        id: watchdog
        interval: 15000
        repeat: false
        onTriggered: {
            root.requestInFlight = false
            root.statusText = "No response — will retry"
        }
    }

    onActiveChanged: {
        if (active) refreshNow()
        else { requestInFlight = false; watchdog.stop() }
    }
}
