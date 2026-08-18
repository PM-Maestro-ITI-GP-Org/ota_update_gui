import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import PdM.Core

/*
 * Remote shell.
 *
 * Two modes, because HMS serves two and the GUI only ever used one:
 *
 *   Single command  — "exec <guest> <cmd>", one request, one reply. This is
 *                     what the old Remote Shell tab did, into a 96px-tall box.
 *   Interactive     — "shellopen"/"shellwrite"/"shellclose", with the guest's
 *                     output streaming back as shell_out chunks. HMS has had
 *                     this since shell.c was written and nothing in the GUI
 *                     ever sent the commands or listened for the replies, so
 *                     the whole feature was unreachable.
 *
 * The interactive session keeps command history on Up/Down and closes itself
 * when the page loses the guest, so HMS's 60s idle reaper is a backstop rather
 * than the normal way sessions end.
 */
Item {
    id: page

    property var mqtt
    property var app
    property var guestsModel

    property string guestId: ""
    property bool   interactive: false
    property bool   sessionOpen: false

    property var history: []
    property int  historyIndex: -1

    function setGuest(id) {
        if (id === guestId) return;
        if (sessionOpen) closeSession();
        guestId = id;
        term.text = "";
    }

    function openSession() {
        if (guestId === "") { app.log("error", "Pick a guest first."); return; }
        term.text = "";
        mqtt.shellOpen(guestId);
    }

    function closeSession() {
        if (!sessionOpen) return;
        mqtt.shellClose(guestId);
        sessionOpen = false;
    }

    function appendTerm(chunk) {
        var atEnd = termScroll.atYEnd;
        term.text += chunk;
        /* Keep the buffer bounded; a `yes` typed into a guest should not grow
           the process until it dies. */
        if (term.text.length > 200000)
            term.text = term.text.slice(-150000);
        if (atEnd) Qt.callLater(function () { termScroll.contentY = Math.max(0, termScroll.contentHeight - termScroll.height) });
    }

    function send() {
        var line = input.text;
        if (line === "") return;
        if (interactive) {
            if (!sessionOpen) { app.log("error", "No shell session open."); return; }
            appendTerm("$ " + line + "\n");
            mqtt.shellWrite(guestId, line + "\n");
        } else {
            if (guestId === "") { app.log("error", "Pick a guest first."); return; }
            appendTerm("$ " + line + "\n");
            mqtt.execCommand(guestId, line);
        }
        history.push(line);
        historyIndex = history.length;
        input.text = "";
    }

    /* --- signals from HMS ------------------------------------------------ */

    function onShellOpened(guest, msg) {
        if (guest !== guestId) return;
        sessionOpen = true;
        interactive = true;
        appendTerm("*** shell opened on " + guest + " — " + msg + "\n");
    }

    function onShellOutput(guest, data) {
        if (guest !== guestId) return;
        appendTerm(data);
    }

    function onShellClosed(guest, msg) {
        if (guest !== guestId) return;
        sessionOpen = false;
        appendTerm("\n*** shell closed — " + msg + "\n");
    }

    function onExecOutput(guest, output) {
        if (guest !== guestId) return;
        appendTerm(output.endsWith("\n") ? output : output + "\n");
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacing

        SectionTitle {
            Layout.fillWidth: true
            title: "Remote shell"
            subtitle: interactive
                ? "Interactive session over a persistent SSH connection to the guest."
                : "Each command is a separate SSH connection; nothing persists between them."
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingTight

            ComboBox {
                id: guestBox
                Layout.preferredWidth: 280
                Layout.preferredHeight: Theme.controlHeight
                font.pixelSize: Theme.fontBody
                model: guestsModel
                textRole: "id"
                enabled: !sessionOpen
                Material.foreground: Theme.textPrimary
                Material.accent: Theme.primary
                onActivated: page.setGuest(guestsModel.get(currentIndex).id)
            }

            StatusPill {
                text: sessionOpen ? "session open" : (interactive ? "closed" : "one-shot")
                tone: sessionOpen ? "success" : "neutral"
            }

            Item { Layout.fillWidth: true }

            Switch {
                id: modeSwitch
                text: "Interactive"
                font.pixelSize: Theme.fontBody
                checked: page.interactive
                enabled: !sessionOpen
                Material.foreground: Theme.textPrimary
                Material.accent: Theme.primary
                onToggled: page.interactive = checked
            }

            FilledButton {
                text: sessionOpen ? "Close session" : "Open session"
                visible: page.interactive
                implicitHeight: Theme.controlHeight
                implicitWidth: 160
                font.pixelSize: Theme.fontBody
                enabled: mqtt.connected && guestId !== ""
                accent: sessionOpen ? Theme.danger : Theme.primary
                onClicked: sessionOpen ? page.closeSession() : page.openSession()
            }

            Button {
                text: "Clear"
                flat: true
                implicitHeight: Theme.controlHeight
                font.pixelSize: Theme.fontBody
                Material.foreground: Theme.textSecondary
                onClicked: term.text = ""
            }
        }

        /* --- terminal --- */
        AppCard {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: Theme.dark ? "#0B1015" : "#1B2430"
            borderColor: Theme.dark ? Theme.outline : "#2A3746"
            padding: Theme.spacingTight

            Flickable {
                id: termScroll
                anchors.fill: parent
                contentWidth: width
                contentHeight: term.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                TextEdit {
                    id: term
                    width: termScroll.width
                    readOnly: true
                    selectByMouse: true
                    /* A terminal is always light-on-dark, in either app theme —
                       switching it to dark-on-white would be the one panel that
                       does not look like a terminal. */
                    color: "#D6E2EF"
                    selectionColor: Theme.primary
                    font.family: Theme.monoFamily
                    font.pixelSize: Theme.fontBody
                    wrapMode: TextEdit.WrapAnywhere
                    textFormat: TextEdit.PlainText
                }
            }

            /* Outside the Flickable: anchoring to it centres on its content
               item, whose height is the (empty) text, so the placeholder sat
               pinned to the top of the terminal instead of in the middle. */
            Text {
                anchors.centerIn: parent
                text: page.guestId === "" ? "Pick a guest to run commands on."
                                          : "No output yet."
                color: "#65788C"
                font.pixelSize: Theme.fontBody
                visible: term.text === ""
            }
        }

        /* --- input --- */
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingTight

            Text {
                text: "$"
                color: Theme.primary
                font.family: Theme.monoFamily
                font.pixelSize: Theme.fontLarge
                font.weight: Font.Bold
            }

            TextField {
                id: input
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.controlHeight
                placeholderText: page.interactive
                    ? "Type a command and press Enter (Up/Down for history)"
                    : "Command to run on the guest, e.g. uname -a"
                font.family: Theme.monoFamily
                font.pixelSize: Theme.fontBody
                enabled: mqtt.connected && page.guestId !== ""
                          && (!page.interactive || page.sessionOpen)
                Material.foreground: Theme.textPrimary
                Material.accent: Theme.primary
                onAccepted: page.send()

                Keys.onUpPressed: {
                    if (page.history.length === 0) return;
                    page.historyIndex = Math.max(0, page.historyIndex - 1);
                    text = page.history[page.historyIndex];
                    cursorPosition = text.length;
                }
                Keys.onDownPressed: {
                    if (page.history.length === 0) return;
                    page.historyIndex = Math.min(page.history.length, page.historyIndex + 1);
                    text = page.historyIndex >= page.history.length
                        ? "" : page.history[page.historyIndex];
                    cursorPosition = text.length;
                }
            }

            FilledButton {
                text: "Run"
                implicitHeight: Theme.controlHeight
                implicitWidth: 110
                font.pixelSize: Theme.fontBody
                enabled: input.enabled && input.text !== ""
                accent: Theme.primary
                onClicked: page.send()
            }
        }
    }

    /* Keep the picker and guestId in step when the list is refreshed or the
       guest is chosen from the Guests page. */
    onGuestIdChanged: {
        for (var i = 0; i < guestsModel.count; ++i) {
            if (guestsModel.get(i).id === guestId) { guestBox.currentIndex = i; return }
        }
    }

    /* Default to the first guest once the list arrives, rather than opening on
       an empty picker with every control disabled and no hint why. */
    Connections {
        target: guestsModel
        function onCountChanged() {
            if (page.guestId === "" && guestsModel.count > 0)
                page.setGuest(guestsModel.get(0).id);
        }
    }

    Component.onCompleted: {
        if (guestId === "" && guestsModel.count > 0)
            setGuest(guestsModel.get(0).id);
    }
}
