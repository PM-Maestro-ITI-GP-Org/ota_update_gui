import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import PdM.Core

/*
 * The guest list on the hypervisor host.
 *
 * Rows are taller and typed larger than before (64px, 15-16px text) because
 * this is the screen people read at a glance. The whole row is still the
 * shortcut into Monitor, but the action buttons now stop the click from
 * reaching it — previously pressing Kill also switched you to the Monitor tab.
 */
Item {
    id: page

    property var mqtt
    property var app
    property var guestsModel

    signal openMonitor(string id, string name, string ip, bool running)

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingTight

            SectionTitle {
                Layout.fillWidth: true
                title: "Guests"
                subtitle: guestsModel.count === 0
                    ? "No guests reported by the host yet."
                    : guestsModel.count + " guest(s) on the host — click a row to monitor it"
            }

            Text {
                text: app.lastUpdateText
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSmall
                Layout.alignment: Qt.AlignVCenter
            }

            Button {
                text: "New guest"
                highlighted: false
                flat: true
                font.pixelSize: Theme.fontBody
                implicitHeight: Theme.controlHeight
                enabled: mqtt.connected && !app.otaBusy
                Material.foreground: Theme.primary
                onClicked: addGuestDialog.open()
            }

            FilledButton {
                text: app.guestsLoading ? "Refreshing…" : "Refresh"
                font.pixelSize: Theme.fontBody
                implicitHeight: Theme.controlHeight
                implicitWidth: 140
                enabled: mqtt.connected && !app.otaBusy
                accent: Theme.primary
                onClicked: { app.guestsLoading = true; mqtt.refreshGuests() }
            }
        }

        AppCard {
            Layout.fillWidth: true
            Layout.fillHeight: true
            padding: Theme.spacingTight

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                /* Column header */
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.headerHeight
                    color: Theme.surfaceVariant
                    radius: Theme.radiusSmall

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacing
                        anchors.rightMargin: Theme.spacing
                        spacing: Theme.spacingTight

                        Text { text: "GUEST";   color: Theme.textSecondary; font.pixelSize: Theme.fontTiny; font.weight: Font.DemiBold; Layout.preferredWidth: 170; Layout.minimumWidth: 120 }
                        Text { text: "HOSTNAME"; color: Theme.textSecondary; font.pixelSize: Theme.fontTiny; font.weight: Font.DemiBold; Layout.fillWidth: true; Layout.minimumWidth: 110 }
                        Text { text: "TYPE";    color: Theme.textSecondary; font.pixelSize: Theme.fontTiny; font.weight: Font.DemiBold; Layout.preferredWidth: 90 }
                        Text { text: "STATE";   color: Theme.textSecondary; font.pixelSize: Theme.fontTiny; font.weight: Font.DemiBold; Layout.preferredWidth: 100 }
                        Text { text: "PID";     color: Theme.textSecondary; font.pixelSize: Theme.fontTiny; font.weight: Font.DemiBold; Layout.preferredWidth: 80 }
                        Text { text: "ADDRESS"; color: Theme.textSecondary; font.pixelSize: Theme.fontTiny; font.weight: Font.DemiBold; Layout.preferredWidth: 140 }
                        Text { text: "ACTIONS"; color: Theme.textSecondary; font.pixelSize: Theme.fontTiny; font.weight: Font.DemiBold; Layout.preferredWidth: 300; horizontalAlignment: Text.AlignRight }
                    }
                }

                ListView {
                    id: guestsList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.topMargin: 6
                    model: guestsModel
                    spacing: 6
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    delegate: Rectangle {
                        id: rowBg
                        width: guestsList.width
                        height: Theme.rowHeight
                        radius: Theme.radiusSmall
                        color: rowHover.hovered ? Theme.primarySoft : Theme.surfaceSunken
                        border.color: rowHover.hovered ? Theme.primary : Theme.outline
                        border.width: 1

                        Behavior on color { ColorAnimation { duration: 90 } }

                        HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: page.openMonitor(model.id, model.name, model.ip, model.running)
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacing
                            anchors.rightMargin: Theme.spacing
                            spacing: Theme.spacingTight

                            Text {
                                text: model.id
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontMedium
                                font.weight: Font.DemiBold
                                Layout.preferredWidth: 170; Layout.minimumWidth: 120
                                elide: Text.ElideRight
                            }
                            Text {
                                text: model.name && model.name !== "-" ? model.name : "—"
                                color: model.name && model.name !== "-" ? Theme.textPrimary : Theme.textDisabled
                                font.pixelSize: Theme.fontBody
                                Layout.fillWidth: true; Layout.minimumWidth: 110
                                elide: Text.ElideRight
                            }
                            Text {
                                text: model.type
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontBody
                                Layout.preferredWidth: 90
                            }
                            StatusPill {
                                Layout.preferredWidth: 100
                                /* A guest whose qvm is up but which is not
                                   answering SSH yet is booting, not broken. */
                                text: (model.running && !model.reachable)
                                    ? "starting" : model.state
                                tone: (model.running && !model.reachable) ? "warning"
                                    : model.running ? "success"
                                    : model.state === "crashed" ? "danger" : "neutral"
                            }
                            Text {
                                /* pid 0 on a running guest is HMS saying it can see the
                                   guest but could not identify its qvm process, which is
                                   why Kill is disabled below. */
                                text: model.pid > 0 ? String(model.pid)
                                                    : (model.running ? "?" : "—")
                                color: model.pid > 0 ? Theme.textPrimary : Theme.textDisabled
                                font.family: Theme.monoFamily
                                font.pixelSize: Theme.fontBody
                                Layout.preferredWidth: 80
                            }
                            Text {
                                text: model.ip && model.ip !== "-" ? model.ip : "—"
                                color: model.ip && model.ip !== "-" ? Theme.textSecondary : Theme.textDisabled
                                font.family: Theme.monoFamily
                                font.pixelSize: Theme.fontBody
                                Layout.preferredWidth: 140
                                elide: Text.ElideRight
                            }

                            RowLayout {
                                Layout.preferredWidth: 300
                                Layout.minimumWidth: 300
                                Layout.maximumWidth: 300
                                Layout.alignment: Qt.AlignRight
                                spacing: 6

                                FilledButton {
                                    text: "Start"
                                    implicitHeight: 38
                                    font.pixelSize: Theme.fontSmall
                                    enabled: !model.running && mqtt.connected && !app.otaBusy
                                    accent: Theme.success
                                    /* Without this the tap fell through to the row's
                                       TapHandler and also switched to Monitor. */
                                    onPressed: rowBg.z = 1
                                    onClicked: {
                                        startDialog.guestId = model.id
                                        startDialog.suggestedIp = model.ip !== "-" ? model.ip : ""
                                        startDialog.open()
                                    }
                                }
                                FilledButton {
                                    text: "Kill"
                                    implicitHeight: 38
                                    font.pixelSize: Theme.fontSmall
                                    enabled: model.running && model.pid > 0 && mqtt.connected && !app.otaBusy
                                    accent: Theme.danger
                                    ToolTip.visible: hovered && model.running && model.pid <= 0
                                    ToolTip.text: "HMS has no PID for this guest — it was started outside HMS and its qvm could not be identified."
                                    onClicked: confirmKill.ask(model.id)
                                }
                                Button {
                                    text: "Info"
                                    flat: true
                                    implicitHeight: 38
                                    font.pixelSize: Theme.fontSmall
                                    enabled: mqtt.connected
                                    Material.foreground: Theme.primary
                                    onClicked: mqtt.guestInfo(model.id)
                                }
                                Button {
                                    text: "Shell"
                                    flat: true
                                    implicitHeight: 38
                                    font.pixelSize: Theme.fontSmall
                                    enabled: model.running && model.reachable && mqtt.connected
                                    Material.foreground: Theme.primary
                                    ToolTip.visible: hovered && model.running && !model.reachable
                                    ToolTip.text: "Guest is still booting — sshd is not listening yet."
                                    onClicked: app.openShellFor(model.id)
                                }
                            }
                        }
                    }

                    Item {
                        anchors.centerIn: parent
                        width: parent.width * 0.7
                        height: emptyCol.implicitHeight
                        visible: guestsModel.count === 0

                        ColumnLayout {
                            id: emptyCol
                            anchors.fill: parent
                            spacing: Theme.spacingTight

                            Text {
                                text: mqtt.connected ? "No guests found on the host"
                                                     : "Not connected"
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontLarge
                                font.weight: Font.DemiBold
                                Layout.alignment: Qt.AlignHCenter
                            }
                            Text {
                                text: mqtt.connected
                                    ? "HMS is running but /guests is empty, or the directories are not named guest-*."
                                    : "Connect to the broker to see the guests on the hypervisor host."
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontBody
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }
                        }
                    }
                }
            }
        }
    }

    /* ------------------------- Start guest ------------------------- */

    Dialog {
        id: startDialog
        anchors.centerIn: Overlay.overlay
        width: 480
        modal: true
        title: "Start " + guestId
        standardButtons: Dialog.Cancel | Dialog.Ok
        Material.background: Theme.surface

        property string guestId: ""
        property string suggestedIp: ""

        onOpened: ipField.text = suggestedIp
        onAccepted: {
            mqtt.startGuest(guestId, ipField.text.trim())
            ipField.text = ""
        }

        ColumnLayout {
            width: parent.width
            spacing: Theme.spacing

            Text {
                text: "HMS stores this address in the guest's .hms_metadata and uses it for every SSH operation. Leave it blank to keep whatever HMS already resolved."
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSmall
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            TextField {
                id: ipField
                Layout.fillWidth: true
                placeholderText: "IP address (optional), e.g. 10.0.0.2"
                font.pixelSize: Theme.fontBody
                Material.foreground: Theme.textPrimary
                Material.accent: Theme.primary
            }
        }
    }

    /* ------------------------- Confirm kill -------------------------
       Kill was a single unguarded click on a row that also navigates. */

    Dialog {
        id: confirmKill
        anchors.centerIn: Overlay.overlay
        width: 440
        modal: true
        title: "Kill guest?"
        standardButtons: Dialog.Cancel | Dialog.Yes
        Material.background: Theme.surface

        property string guestId: ""
        function ask(id) { guestId = id; open() }
        onAccepted: mqtt.killGuest(guestId)

        Text {
            width: parent.width
            text: "SIGKILL is sent to " + confirmKill.guestId +
                  "'s qvm process. The guest is not shut down cleanly."
            color: Theme.textPrimary
            font.pixelSize: Theme.fontBody
            wrapMode: Text.Wrap
        }
    }

    /* ------------------------- Add guest -------------------------
       HMS has served `addguest` since ota.c grew it; nothing ever sent it. */

    Dialog {
        id: addGuestDialog
        anchors.centerIn: Overlay.overlay
        width: 560
        modal: true
        title: "Create a new guest"
        standardButtons: Dialog.Cancel | Dialog.Ok
        Material.background: Theme.surface

        onAccepted: mqtt.addGuest(newId.text.trim(), newIfs.text.trim(),
                                  newConf.text.trim(), newIp.text.trim())

        ColumnLayout {
            width: parent.width
            spacing: Theme.spacingTight

            Text {
                text: "HMS creates /guests/<id> on the host and pulls the boot image and qvmconf from the upload server. Both files must already be on the server — stage them from the OTA tab first."
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSmall
                wrapMode: Text.Wrap
                Layout.fillWidth: true
                Layout.bottomMargin: Theme.spacingTight
            }

            TextField {
                id: newId
                Layout.fillWidth: true
                placeholderText: "Guest id — must start with 'guest-' to be discovered"
                text: "guest-"
                font.pixelSize: Theme.fontBody
                Material.accent: Theme.primary
            }
            TextField {
                id: newIfs
                Layout.fillWidth: true
                placeholderText: "Boot image path on the server"
                text: mqtt.serverUploadDir + "/"
                font.pixelSize: Theme.fontBody
                Material.accent: Theme.primary
            }
            TextField {
                id: newConf
                Layout.fillWidth: true
                placeholderText: "qvmconf path on the server"
                text: mqtt.serverUploadDir + "/"
                font.pixelSize: Theme.fontBody
                Material.accent: Theme.primary
            }
            TextField {
                id: newIp
                Layout.fillWidth: true
                placeholderText: "IP address (optional)"
                font.pixelSize: Theme.fontBody
                Material.accent: Theme.primary
            }
        }
    }
}
