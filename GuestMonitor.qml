import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import PdM.Core
import "StatsParser.js" as Stats

/*
 * Live host and guest statistics.
 *
 * Every running guest is shown automatically now, alongside the hypervisor
 * host, with no selection step. It used to poll exactly one target at a time
 * -- whichever guest a picker in the header was set to -- and every other
 * guest simply had no way to appear on this page at all. Two guests running
 * side by side meant clicking back and forth to see one at a time.
 *
 * The page now asks HMS about the host plus every guest currently reported
 * as running (from the shared guest list) on each poll, and renders one card
 * per reply that comes back running. A guest that stops -- or was never
 * running -- gets no card at all, per the same rule the host always follows:
 * the hypervisor card is the one constant, guest cards come and go with
 * whether qvm actually has them up.
 *
 * This relies on hms/main.c's per-target stats coalescing (see stats_targets
 * there): asking about several guests and the host at once only works
 * cleanly because each target now has its own in-flight slot instead of
 * sharing one, which used to let concurrent targets stomp on each other's
 * bookkeeping.
 */
Item {
    id: root

    property bool active: false
    /* Set by main.qml. Only used for diag() -- the page never talks to MQTT
       directly, it goes through the requestStats signal. */
    property var mqttRef: null
    property bool autoRefresh: true

    /* Set by main.qml; the source of truth for which guests exist and which
       of them qvm currently has running. */
    property var guests: null
    /* 15s, not 5s or 3s. Each poll parses a few hundred lines of `top`/`pidin`
       output in JS on the GUI thread and then refills a list model per
       target, so the interval is a direct tax on how responsive the whole
       app feels. A guest stats round trip also measures ~21s on the board
       (the ssh handshake alone is ~10s), so anything shorter than that just
       queues work that the previous poll's watchdog then throws away. */
    property int  pollIntervalMs: 15000

    /* Every process that arrives is worth showing now: the QNX top table is
       capped at 100 threads on the host side, and a Linux guest's full table
       fits comfortably here. The view is sorted by CPU descending, and the
       cost of the refill is proportional to how many rows there are. */
    property int  maxRows: 400

    property string lastUpdated: ""
    property string statusText: ""

    /* Which cards the user wants to see. Host is a single toggle; each guest
       carries its own "selected" role on its guestCards row (set true when
       the row is created in syncCards(), so a guest that only just started
       is shown by default rather than hidden until the user opts it in). */
    property bool hostSelected: true

    /* Targets ("" for host, a guest id otherwise) currently awaiting a
       reply. A plain map for membership tests in JS; inFlightCount is the
       property bindings actually watch, since mutating a `var` map in place
       does not raise a change notification on its own. */
    property var inFlight: ({})
    property int inFlightCount: 0

    signal requestStats(string id)

    ListModel { id: hostProcs }
    property var hostSnap: null
    property var hostSummary: null

    /* One row per guest currently shown: gid, name, ip, statsRunning (HMS
       could reach it over ssh), error, hostname, loadText, cpusText,
       ramUsedBytes, ramTotalBytes, kernel, lastUpdated. Rows are added and
       removed by syncCards() to track root.guests, and filled in by
       onStats(). */
    ListModel { id: guestCards }
    /* gid -> ListModel of that guest's processes, and gid -> its previous
       snapshot (for the CPU% delta). Neither is read from a QML binding, so
       plain JS mutation is fine -- these exist purely as lookup tables for
       onStats() and are not something the UI observes directly. */
    property var procModelsByGuest: ({})
    property var prevGuestSnaps: ({})

    /*
     * Update in place rather than clear-and-refill.
     *
     * model.clear() followed by append() per row makes the ListView discard and
     * rebuild every delegate, twice, every poll -- which is what the periodic
     * hitch was. Setting existing rows leaves the delegates alone.
     */
    function fillModel(model, view) {
        if (!model) return
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

    function cardIndex(gid) {
        for (var i = 0; i < guestCards.count; ++i)
            if (guestCards.get(i).gid === gid) return i
        return -1
    }

    /* Bring guestCards in step with which guests qvm currently has running.
       A guest that is not running gets no card -- not a "stopped" card, an
       absent one, per the rule this page now follows throughout. */
    function syncCards() {
        if (!root.guests) return
        var wanted = {}
        for (var i = 0; i < root.guests.count; ++i) {
            var g = root.guests.get(i)
            if (!g.running) continue
            wanted[g.id] = true
            var idx = cardIndex(g.id)
            if (idx < 0) {
                /* Create the proc model BEFORE appending the row. The
                   Repeater instantiates its delegate synchronously as soon
                   as the row lands in guestCards, and the delegate's
                   ProcTable reads procModelsByGuest[gid] once at that
                   instant -- appending first left it reading a key that did
                   not exist yet, which crashed with "Cannot read property
                   'count' of null" the moment a second guest came up. */
                if (!procModelsByGuest[g.id])
                    procModelsByGuest[g.id] = Qt.createQmlObject(
                        "import QtQuick; ListModel {}", root, "procModel_" + g.id)
                guestCards.append({
                    gid: g.id, name: g.name || "", ip: g.ip || "",
                    statsRunning: false, error: "",
                    hostname: "", loadText: "—", cpusText: "—",
                    ramUsedBytes: 0, ramTotalBytes: 0, kernel: "",
                    lastUpdated: "", selected: true
                })
            } else {
                if (guestCards.get(idx).name !== (g.name || ""))
                    guestCards.setProperty(idx, "name", g.name || "")
                if (guestCards.get(idx).ip !== (g.ip || ""))
                    guestCards.setProperty(idx, "ip", g.ip || "")
            }
        }
        for (var k = guestCards.count - 1; k >= 0; --k) {
            var gid = guestCards.get(k).gid
            if (!wanted[gid]) guestCards.remove(k)
            /* procModelsByGuest/prevGuestSnaps for gid are deliberately kept:
               the same guest restarting a poll or two later refills them
               instead of starting from an empty table again. */
        }
    }

    function onStats(json) {
        var obj
        try {
            obj = JSON.parse(json)
        } catch (e) {
            statusText = "Parse error: " + e.message
            return
        }
        var replyFor = (obj.guest_id === undefined || obj.guest_id === null)
                       ? "" : obj.guest_id

        /* Accept a reply for any target we actually asked about, not only a
           single "currently selected" one -- that restriction is what used
           to make it impossible to show more than one guest at a time. A
           reply for a target we are not waiting on (a stale one from before
           a guest disappeared, say) is dropped. */
        if (!inFlight[replyFor]) {
            if (mqttRef) mqttRef.diag("monitor", "DROP unexpected reply for '" + replyFor + "'")
            return
        }
        delete inFlight[replyFor]
        inFlightCount = Math.max(0, inFlightCount - 1)
        if (inFlightCount === 0) watchdog.stop()

        lastUpdated = Qt.formatTime(new Date(), "hh:mm:ss")
        statusText = ""

        try {
            if (replyFor === "") {
                var h = Stats.parseSnapshot(obj.host)
                hostSummary = h
                var prevH = hostSnap
                hostSnap = h
                fillModel(hostProcs, Stats.buildView(h, prevH, pollIntervalMs))
                return
            }

            var idx = cardIndex(replyFor)
            if (idx < 0) return   /* stopped or removed between request and reply */

            var running = (obj.guest_running === true)
            guestCards.setProperty(idx, "statsRunning", running)
            guestCards.setProperty(idx, "error", obj.guest_error || "")
            guestCards.setProperty(idx, "lastUpdated", lastUpdated)

            if (running && obj.guest && obj.guest !== "") {
                var g = Stats.parseSnapshot(obj.guest)
                var prevG = prevGuestSnaps[replyFor] || null
                prevGuestSnaps[replyFor] = g
                guestCards.setProperty(idx, "hostname", g.hostname || "—")
                guestCards.setProperty(idx, "loadText", loadText(g))
                guestCards.setProperty(idx, "cpusText",
                    g.cpus > 0 ? String(g.cpus) + (g.threads > 0 ? " · " + g.threads + " threads" : "")
                               : "—")
                guestCards.setProperty(idx, "ramUsedBytes", g.ram.used || 0)
                guestCards.setProperty(idx, "ramTotalBytes", g.ram.total || 0)
                guestCards.setProperty(idx, "kernel", g.kernel || "—")
                fillModel(procModelsByGuest[replyFor], Stats.buildView(g, prevG, pollIntervalMs))
            }
        } catch (e2) {
            statusText = "Parse error: " + e2.message
        }
    }

    /*
     * The broker went away and came back.
     *
     * A request that was outstanding when the link dropped is never answered:
     * HMS's reply went to a session that no longer exists. Clearing every
     * in-flight target and asking again immediately means the page does not
     * sit waiting out its own 60s watchdog for a link that is already back.
     */
    function onLinkChanged(up) {
        if (mqttRef) mqttRef.diag("monitor", "link " + (up ? "up" : "down") + " inFlight=" + inFlightCount)
        inFlight = ({})
        inFlightCount = 0
        watchdog.stop()
        if (!up) {
            statusText = "Link lost"
            return
        }
        statusText = ""
        if (active) refreshNow()
    }

    function refreshNow() {
        syncCards()
        var targets = [""]
        for (var i = 0; i < guestCards.count; ++i)
            targets.push(guestCards.get(i).gid)

        var fired = false
        for (var t = 0; t < targets.length; ++t) {
            var id = targets[t]
            if (inFlight[id]) continue
            inFlight[id] = true
            inFlightCount++
            fired = true
            requestStats(id)
        }
        if (mqttRef) mqttRef.diag("monitor", "refreshNow: " + targets.length + " target(s), " + inFlightCount + " in flight")
        if (fired) {
            statusText = "Fetching…"
            watchdog.start()
        }
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
        /* 0 = uncapped (unchanged for every other Stat use). KERNEL sets this:
           its value is a full `uname -a` line, and a Linux guest's is much
           longer than a QNX one's -- Text.implicitWidth reflects the FULL
           unwrapped string regardless of the elide set on valueText below
           (elide only trims what is actually painted, not the reported
           implicit size), so without a cap this tile alone could balloon to
           4-5x a QNX card's width. That widened the Flow's row (or pushed it
           onto an extra row) only for whichever guest had the longer kernel
           string, which ate into that specific card's fixed-height ProcTable
           below it and made it visibly shorter than the other cards'. */
        property int maxWidth: 0

        implicitWidth: maxWidth > 0
            ? Math.max(minWidth, Math.min(valueText.implicitWidth + 28, maxWidth))
            : Math.max(minWidth, valueText.implicitWidth + 28)
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
                subtitle: guestCards.count > 0
                    ? "Hypervisor host and " + guestCards.count + " running guest"
                      + (guestCards.count > 1 ? "s" : "") + " — shown automatically."
                    : "Hypervisor host only — no guest is currently running."
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
                enabled: root.active && root.inFlightCount === 0
                accent: Theme.primary
                onClicked: root.refreshNow()
            }
        }

        /* Which cards to show. All on by default -- unchecking one just hides
           its card below, it does not stop polling it (unselecting the
           hypervisor host while still watching a guest would otherwise have
           to keep the host request in flight anyway, since it always answers
           in the same round). */
        Flow {
            Layout.fillWidth: true
            spacing: Theme.spacingTight

            CheckBox {
                text: "Hypervisor host"
                checked: root.hostSelected
                font.pixelSize: Theme.fontSmall
                Material.foreground: Theme.textPrimary
                Material.accent: Theme.primary
                onToggled: root.hostSelected = checked
            }

            Repeater {
                model: guestCards
                delegate: CheckBox {
                    required property int index
                    required property string gid
                    required property string name
                    required property bool selected

                    text: "Guest — " + gid + (name !== "" && name !== "-" ? " · " + name : "")
                    checked: selected
                    font.pixelSize: Theme.fontSmall
                    Material.foreground: Theme.textPrimary
                    Material.accent: Theme.primary
                    onToggled: guestCards.setProperty(index, "selected", checked)
                }
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

                /* ---- host: shown whenever selected ---- */
                AppCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 400
                    visible: root.hostSelected

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
                                maxWidth: 420
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

                /* ---- one card per guest currently running; none otherwise ---- */
                Repeater {
                    model: guestCards

                    delegate: AppCard {
                        required property string gid
                        required property string name
                        required property string ip
                        required property bool statsRunning
                        required property string error
                        required property string hostname
                        required property string loadText
                        required property string cpusText
                        required property real ramUsedBytes
                        required property real ramTotalBytes
                        required property string kernel
                        required property bool selected

                        Layout.fillWidth: true
                        /* Fixed at 400 regardless of statsRunning, matching the
                           hypervisor host card and every other guest card --
                           the old "140 while waiting for the first reply"
                           made the row heights jump around, and made a guest
                           still booting look like a smaller, lesser card. */
                        Layout.preferredHeight: 400
                        visible: selected

                        ColumnLayout {
                            anchors.fill: parent
                            spacing: Theme.spacingTight

                            RowLayout {
                                Layout.fillWidth: true
                                Text {
                                    text: "Guest — " + gid + (name !== "" && name !== "-" ? " · " + name : "")
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontMedium
                                    font.weight: Font.DemiBold
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                                StatusPill {
                                    text: "running"
                                    tone: "success"
                                }
                            }

                            /* The guest itself is running (that came straight
                               from the guest list, which is authoritative) --
                               this fires only when HMS could not collect
                               stats from it over SSH, which used to be
                               indistinguishable from the guest being down. */
                            ColumnLayout {
                                Layout.fillWidth: true
                                visible: !statsRunning
                                spacing: 4

                                Text {
                                    Layout.fillWidth: true
                                    text: error !== ""
                                        ? "Guest is running, but HMS could not collect statistics from it yet."
                                        : "Waiting for the first reply from this guest…"
                                    color: Theme.warning
                                    font.pixelSize: Theme.fontBody
                                    wrapMode: Text.Wrap
                                }
                                Text {
                                    Layout.fillWidth: true
                                    visible: error !== ""
                                    text: error
                                    color: Theme.textSecondary
                                    font.family: Theme.monoFamily
                                    font.pixelSize: Theme.fontSmall
                                    wrapMode: Text.WrapAnywhere
                                }
                            }

                            Flow {
                                Layout.fillWidth: true
                                visible: statsRunning
                                spacing: Theme.spacingTight

                                Stat { label: "HOSTNAME"; value: hostname || "—" }
                                Stat { label: "LOAD";     value: loadText }
                                Stat { label: "CPUS";     value: cpusText }
                                RamStat { usedBytes: ramUsedBytes; totalBytes: ramTotalBytes }
                                Stat { label: "KERNEL"; minWidth: 320; maxWidth: 420; value: kernel || "—" }
                            }

                            ProcTable {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                visible: statsRunning
                                procModel: root.procModelsByGuest[gid]
                                emptyText: "Guest process data appears on the next poll."
                            }
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
        /* refreshNow() guards every target individually, so it is always
           safe to call on a tick -- a target still answering from the last
           round is simply skipped, while the host (usually done in well
           under a second) or a guest that just finished gets asked again. */
        onTriggered: root.refreshNow()
    }

    Timer {
        id: watchdog
        /*
         * Must outlast HMS's own ssh cap, or this gives up on every single
         * guest poll.
         *
         * HMS kills its own ssh at 45s and replies immediately after, so 60s
         * leaves room for that plus the round trip to the broker. This is the
         * backstop for HMS being gone entirely, not a latency budget -- and
         * now covers however many targets are in flight at once, not just one.
         */
        interval: 60000
        repeat: false
        onTriggered: {
            if (root.mqttRef) root.mqttRef.diag("monitor", "WATCHDOG fired, " + root.inFlightCount + " target(s) still pending")
            root.inFlight = ({})
            root.inFlightCount = 0
            root.statusText = "No response — will retry"
        }
    }

    Connections {
        target: root.guests
        function onCountChanged() { root.syncCards() }
        function onDataChanged()  { root.syncCards() }
    }

    onActiveChanged: {
        if (mqttRef)
            mqttRef.diag("monitor", "active=" + active + " inFlight=" + inFlightCount)
        if (active) refreshNow()
        else { inFlight = ({}); inFlightCount = 0; watchdog.stop() }
    }

    Component.onCompleted: syncCards()
}
