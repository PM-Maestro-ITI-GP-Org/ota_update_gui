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

    /* Set by main.qml; drives the guest picker in the header. Named `guests`,
       not `guestsModel`: a property of that name would shadow main.qml.s
       ListModel id and `guestsModel: guestsModel` would bind to itself. */
    property var guests: null
    /* 5s, not 3s. Each poll parses a few hundred lines of `top`/`pidin` output
       in JS on the GUI thread and then refills two list models, so the interval
       is a direct tax on how responsive the whole app feels. */
    /* 15s, not 5s. A poll SSHes into the guest and the round trip measures
       ~21s on the board, so a 5s timer only ever queued work that the
       requestInFlight guard then threw away -- and made the CPU% deltas, which
       are computed against this interval, wrong whenever one did get through. */
    property int  pollIntervalMs: 15000

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

        /*
         * A reply to a request made before the selection changed.
         *
         * Discarding it is right -- it describes a guest the page is no longer
         * showing -- but discarding it and stopping there was what made
         * switching guests look like a hang. HMS used to coalesce the request
         * sent on the switch against the one already running, so nothing was
         * ever coming: the page sat on "Fetching..." with Refresh disabled
         * until the 60s watchdog. HMS now coalesces per target and answers
         * both, so this is only the ordering case -- ask again rather than
         * wait, and the page recovers in one round trip instead of one poll.
         *
         * A missing guest_id reads as "", which is what a host-only reply
         * carries, so such a reply is no longer accepted while a guest is
         * selected. It used to be, and it blanked the guest panel.
         */
        var replyFor = (obj.guest_id === undefined || obj.guest_id === null)
                       ? "" : obj.guest_id
        if (replyFor !== guestId) {
            refreshNow()
            return
        }

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
                    : "Hypervisor host only — choose a guest to monitor it alongside."
            }

            Text {
                text: root.lastUpdated !== "" ? "Updated " + root.lastUpdated : ""
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSmall
                Layout.alignment: Qt.AlignVCenter
            }

            /*
             * Guest picker.
             *
             * The page told you to "click a row on the Guests page", which is
             * one way in and was the only one -- landing here from the
             * navigation rail left you reading an instruction with nothing on
             * screen to act on. Clicking a guest row still works and still
             * lands here; this just stops that being mandatory.
             */
            ComboBox {
                id: guestPicker
                Layout.preferredWidth: 240
                Layout.preferredHeight: Theme.controlHeight
                font.pixelSize: Theme.fontBody
                textRole: "label"
                valueRole: "id"
                enabled: root.guests && root.guests.count > 0
                Material.foreground: Theme.textPrimary
                Material.accent: Theme.primary

                /* "(host only)" first, then every guest. Rebuilt whenever the
                   list changes so a guest appearing or disappearing does not
                   silently shift the selection onto a different one. */
                model: ListModel { id: pickerModel }

                function rebuild() {
                    var keep = root.guestId;
                    pickerModel.clear();
                    pickerModel.append({ label: "Host only", id: "" });
                    if (root.guests) {
                        for (var i = 0; i < root.guests.count; ++i) {
                            var g = root.guests.get(i);
                            pickerModel.append({
                                label: g.id + (g.running ? "" : "  (stopped)"),
                                id: g.id
                            });
                        }
                    }
                    for (var j = 0; j < pickerModel.count; ++j)
                        if (pickerModel.get(j).id === keep) { currentIndex = j; return }
                    currentIndex = 0;
                }

                onActivated: {
                    var id = pickerModel.get(currentIndex).id;
                    if (id === "") { root.setGuest("", "", "", false); return }
                    for (var i = 0; i < root.guests.count; ++i) {
                        var g = root.guests.get(i);
                        if (g.id === id) { root.setGuest(g.id, g.name, g.ip, g.running); return }
                    }
                }

                /*
                 * Labels carry live state ("(stopped)"), so they have to follow
                 * the model's CONTENTS, not just its length.
                 *
                 * main.qml updates the guest rows in place, so starting a guest
                 * changes its `running` field while the row count stays the
                 * same. Watching only onCountChanged left this frozen at
                 * whatever the guests happened to be when the page first
                 * loaded -- the picker went on saying "(stopped)" for a guest
                 * the Guests tab was showing as running.
                 *
                 * Labels are patched rather than rebuilt: rebuild() clears the
                 * model, which would collapse the dropdown under the user if it
                 * happened to be open when a poll landed.
                 */
                function syncLabels() {
                    if (!root.guests) return;
                    /* row 0 is "Host only", so guest i lives at row i + 1 */
                    for (var i = 0; i < root.guests.count && i + 1 < pickerModel.count; ++i) {
                        var g = root.guests.get(i);
                        var want = g.id + (g.running ? "" : "  (stopped)");
                        if (pickerModel.get(i + 1).label !== want)
                            pickerModel.setProperty(i + 1, "label", want);
                    }
                }

                Component.onCompleted: rebuild()

                Connections {
                    target: root.guests
                    function onCountChanged() { guestPicker.rebuild() }
                    function onDataChanged()  { guestPicker.syncLabels() }
                }
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
                            text: "No guest selected — pick one from the list above, "
                                + "or click a guest row on the Guests page."
                            color: Theme.textSecondary
                            font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap
                        }

                        /* Shown when the guest is stopped, AND when it is running
                           but the stats could not be collected.

                           This used to be gated on !guestRunning alone, which
                           was fine only while HMS reported a failed stats fetch
                           as "not running". Now that those are two separate
                           facts, a running guest whose fetch failed fell
                           between them: empty tiles, an empty process table,
                           and not a word about why. */
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: root.guestId !== ""
                                     && (!root.guestRunning || root.guestError !== "")
                            spacing: 4

                            Text {
                                Layout.fillWidth: true
                                text: root.guestError !== ""
                                    ? (root.guestRunning
                                        ? "Guest is running, but HMS could not collect statistics from it."
                                        : "No statistics for this guest — HMS could not reach it over SSH.")
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
        /*
         * Must outlast HMS's own ssh cap, or this gives up on every single
         * guest poll.
         *
         * It was 15s while a guest stats round trip measures ~21s on the board
         * -- the ssh handshake into the guest alone is ~10s. So the watchdog
         * fired first, every time, cleared requestInFlight, printed "No
         * response", and let the poll timer fire a fresh request that the reply
         * to the previous one then raced. The Monitor never settled even when
         * HMS answered perfectly.
         *
         * HMS kills its own ssh at 45s and replies immediately after, so 60s
         * leaves room for that plus the round trip to the broker. This is the
         * backstop for HMS being gone entirely, not a latency budget.
         */
        interval: 60000
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
