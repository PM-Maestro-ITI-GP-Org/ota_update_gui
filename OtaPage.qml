import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import App 1.0

/*
 * Partition updates and file delivery.
 *
 * The three-step flow is unchanged (upload to the server, pull down to the
 * host, apply into /guests/<id>) but it is now stated on screen as a stepper
 * instead of three booleans the user had to infer from a progress bar's
 * colour. The panels are cards on a scrolling column rather than a fixed-height
 * GridLayout that clipped its own content below ~700px.
 */
Item {
    id: page

    property var mqtt
    property var app
    property var guestsModel
    property var partitionsModel
    property var stagedModel
    property var sendModel

    readonly property string guestId: app.selectedGuestId

    function stepTone(done, active) {
        return done ? "success" : (active ? "primary" : "neutral");
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true

        ColumnLayout {
            width: page.width
            spacing: Theme.spacing

            /* ---------------- guest selector + stepper ---------------- */

            AppCard {
                Layout.fillWidth: true
                Layout.preferredHeight: headerCol.implicitHeight + Theme.spacing * 2

                ColumnLayout {
                    id: headerCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    spacing: Theme.spacing

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingTight

                        SectionTitle {
                            Layout.fillWidth: true
                            title: "OTA update"
                            subtitle: "Replace partition files on a guest and restart it."
                        }

                        ComboBox {
                            Layout.preferredWidth: 260
                            Layout.preferredHeight: Theme.controlHeight
                            font.pixelSize: Theme.fontBody
                            model: guestsModel
                            textRole: "id"
                            enabled: mqtt.connected && !app.otaBusy
                            currentIndex: app.guestIndex
                            Material.foreground: Theme.textPrimary
                            Material.accent: Theme.primary
                            onActivated: app.selectGuestByIndex(currentIndex)
                        }

                        Button {
                            text: "Reload partitions"
                            flat: true
                            implicitHeight: Theme.controlHeight
                            font.pixelSize: Theme.fontBody
                            enabled: mqtt.connected && !app.otaBusy && page.guestId !== ""
                            Material.foreground: Theme.primary
                            onClicked: app.refreshPartitions()
                        }
                    }

                    /* Stepper */
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Repeater {
                            model: [
                                { n: 1, label: "Upload to server",
                                  done: app.chkUploaded,   active: !app.chkUploaded && stagedModel.count > 0 },
                                { n: 2, label: "Pull to host",
                                  done: app.chkDownloaded, active: app.otaDeploying && !app.chkDownloaded },
                                { n: 3, label: "Apply and restart",
                                  done: app.chkApplied,    active: app.otaDeploying && app.chkDownloaded && !app.chkApplied }
                            ]

                            delegate: RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingTight

                                Rectangle {
                                    implicitWidth: 34; implicitHeight: 34
                                    radius: 17
                                    color: modelData.done ? Theme.success
                                         : modelData.active ? Theme.primary : Theme.surfaceVariant
                                    border.color: modelData.done || modelData.active
                                        ? "transparent" : Theme.outline
                                    border.width: 1

                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.done ? "✓" : String(modelData.n)
                                        color: modelData.done || modelData.active
                                            ? Theme.textOnAccent : Theme.textSecondary
                                        font.pixelSize: Theme.fontBody
                                        font.weight: Font.Bold
                                    }
                                }

                                Text {
                                    text: modelData.label
                                    color: modelData.done || modelData.active
                                        ? Theme.textPrimary : Theme.textSecondary
                                    font.pixelSize: Theme.fontBody
                                    font.weight: modelData.active ? Font.DemiBold : Font.Normal
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 2
                                    visible: modelData.n < 3
                                    color: modelData.done ? Theme.success : Theme.outline
                                }
                            }
                        }
                    }

                    /* Progress */
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        ProgressBar {
                            Layout.fillWidth: true
                            from: 0; to: 100
                            value: app.progressPercent
                            /* partitionBusy, not otaBusy: otaBusy also
                               includes pushingNow (it is the shared button
                               lock across all three flows), which made this
                               bar animate for a Send-to-guest push that
                               never touches progressPercent -- it has its
                               own bar/tracker below. */
                            indeterminate: app.partitionBusy && app.progressPercent <= 0
                            /* Green once the Replace -> Apply/fetch flow's
                               last step finished successfully -- not only
                               when chkApplied is set, since a fetch that
                               still has more files queued finishes too, just
                               not with Apply itself. */
                            Material.accent: (!app.partitionBusy && app.lastOtaSucceeded) ? Theme.success : Theme.primary
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                Layout.fillWidth: true
                                text: app.otaStageLabel
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontSmall
                                wrapMode: Text.Wrap
                            }
                            Text {
                                text: app.partitionBusy ? Math.round(app.progressPercent) + "%" : ""
                                color: Theme.primary
                                font.pixelSize: Theme.fontSmall
                                font.weight: Font.DemiBold
                            }
                        }
                    }
                }
            }

            /* ---------------- partitions + staging ---------------- */

            GridLayout {
                Layout.fillWidth: true
                columns: page.width > 980 ? 2 : 1
                columnSpacing: Theme.spacing
                rowSpacing: Theme.spacing

                /* Partitions on the guest */
                AppCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 340

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: Theme.spacingTight

                        SectionTitle {
                            Layout.fillWidth: true
                            title: "Partitions on " + (page.guestId !== "" ? page.guestId : "—")
                            subtitle: app.currentGuestType !== ""
                                ? "Guest type: " + app.currentGuestType + " — press Replace to pick a local file."
                                : "Select a guest to list its partition files."
                        }

                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            model: partitionsModel
                            spacing: 6
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                            delegate: Rectangle {
                                width: ListView.view.width
                                height: 52
                                radius: Theme.radiusSmall
                                color: Theme.surfaceSunken
                                border.color: Theme.outline
                                border.width: 1

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.spacingTight
                                    anchors.rightMargin: Theme.spacingTight
                                    spacing: Theme.spacingTight

                                    StatusPill {
                                        text: model.kind
                                        tone: model.kind === "conf" ? "neutral" : "primary"
                                        horizontalPadding: 8
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Text {
                                            text: model.name
                                            color: Theme.textPrimary
                                            font.pixelSize: Theme.fontBody
                                            elide: Text.ElideMiddle
                                            Layout.fillWidth: true
                                        }
                                        Text {
                                            text: model.exists ? app.fmtSize(model.size) : "missing on host"
                                            color: model.exists ? Theme.textSecondary : Theme.warning
                                            font.pixelSize: Theme.fontTiny
                                        }
                                    }

                                    Button {
                                        text: "Replace"
                                        flat: true
                                        implicitHeight: 36
                                        font.pixelSize: Theme.fontSmall
                                        enabled: !app.otaBusy
                                        Material.foreground: Theme.primary
                                        onClicked: app.pickPartitionFile(model.name)
                                    }
                                }
                            }

                            Text {
                                anchors.centerIn: parent
                                text: page.guestId === "" ? "No guest selected."
                                                          : "No partition files reported."
                                color: Theme.textDisabled
                                font.pixelSize: Theme.fontBody
                                visible: partitionsModel.count === 0
                            }
                        }
                    }
                }

                /* Staged replacements */
                AppCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 340

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: Theme.spacingTight

                        SectionTitle {
                            Layout.fillWidth: true
                            title: "Staged — " + stagedModel.count + " replacement(s)"
                            subtitle: "Uploaded " + app.sentCount() + "/" + stagedModel.count +
                                      " · pulled to host " + app.readyCount() + "/" + stagedModel.count
                        }

                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            model: stagedModel
                            spacing: 6
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                            delegate: Rectangle {
                                width: ListView.view.width
                                height: 62
                                radius: Theme.radiusSmall
                                color: Theme.surfaceSunken
                                border.color: model.downloaded ? Theme.success
                                            : model.sent ? Theme.primary : Theme.outline
                                border.width: 1

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.spacingTight
                                    anchors.rightMargin: Theme.spacingTight
                                    spacing: Theme.spacingTight

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        Text {
                                            text: model.destName
                                            color: Theme.textPrimary
                                            font.pixelSize: Theme.fontBody
                                            font.weight: Font.DemiBold
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                        Text {
                                            text: model.local
                                            color: Theme.textSecondary
                                            font.pixelSize: Theme.fontTiny
                                            elide: Text.ElideLeft
                                            Layout.fillWidth: true
                                        }
                                    }

                                    StatusPill {
                                        visible: model.state !== ""
                                        horizontalPadding: 8
                                        text: model.state === "uploading"   ? "uploading"
                                            : model.state === "uploaded"    ? "uploaded"
                                            : model.state === "downloading" ? "pulling"
                                            : model.state === "done"        ? "ready" : model.state
                                        tone: model.state === "done" ? "success" : "primary"
                                    }

                                    ToolButton {
                                        text: "✕"
                                        font.pixelSize: Theme.fontBody
                                        enabled: !app.otaBusy
                                        Material.foreground: Theme.danger
                                        onClicked: stagedModel.remove(index)
                                    }
                                }
                            }

                            Text {
                                anchors.centerIn: parent
                                width: parent.width - 40
                                text: "Nothing staged. Press Replace next to a partition."
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.Wrap
                                color: Theme.textDisabled
                                font.pixelSize: Theme.fontBody
                                visible: stagedModel.count === 0
                            }
                        }
                    }
                }
            }

            /* ---------------- actions ---------------- */

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingTight

                FilledButton {
                    text: app.uploadingNow ? "Uploading…" : "Upload and pull"
                    implicitHeight: Theme.controlHeight
                    implicitWidth: 200
                    font.pixelSize: Theme.fontBody
                    enabled: mqtt.connected && !app.otaBusy
                             && (stagedModel.count > app.sentCount()
                                 || app.sentCount() > app.readyCount())
                    accent: Theme.primary
                    onClicked: app.sendAll()
                }

                FilledButton {
                    text: "Apply and restart guest"
                    implicitHeight: Theme.controlHeight
                    implicitWidth: 230
                    font.pixelSize: Theme.fontBody
                    enabled: mqtt.connected && app.chkDownloaded && !app.otaDeploying
                    accent: Theme.success
                    onClicked: confirmApply.open()
                }

                Item { Layout.fillWidth: true }
            }

            /* ---------------- send arbitrary files ---------------- */

            AppCard {
                Layout.fillWidth: true
                Layout.preferredHeight: sendCol.implicitHeight + Theme.spacing * 2

                ColumnLayout {
                    id: sendCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    spacing: Theme.spacingTight

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingTight

                        SectionTitle {
                            Layout.fillWidth: true
                            title: "Send files into the running guest"
                            subtitle: "Packed into one archive, pulled by the host and unpacked inside the guest at each file's path."
                        }

                        Button {
                            text: "Add file"
                            flat: true
                            implicitHeight: Theme.controlHeight
                            font.pixelSize: Theme.fontBody
                            enabled: mqtt.connected && !app.otaBusy && page.guestId !== ""
                            Material.foreground: Theme.primary
                            onClicked: app.pickSendFile()
                        }

                        Button {
                            text: "Save…"
                            flat: true
                            implicitHeight: Theme.controlHeight
                            font.pixelSize: Theme.fontBody
                            enabled: !app.otaBusy && sendModel.count > 0
                            Material.foreground: Theme.primary
                            ToolTip.visible: hovered
                            ToolTip.text: "Save this list of files and destinations to reload later"
                            onClicked: savePresetDialog.open()
                        }

                        Button {
                            text: "Load…"
                            flat: true
                            implicitHeight: Theme.controlHeight
                            font.pixelSize: Theme.fontBody
                            enabled: !app.otaBusy && app.sendPresetNames().length > 0
                            Material.foreground: Theme.primary
                            ToolTip.visible: hovered
                            ToolTip.text: "Load a previously saved list of files and destinations"
                            onClicked: loadPresetDialog.open()
                        }

                        FilledButton {
                            text: app.pushingNow ? "Sending…" : "Send to guest"
                            implicitHeight: Theme.controlHeight
                            implicitWidth: 170
                            font.pixelSize: Theme.fontBody
                            enabled: mqtt.connected && !app.otaBusy && sendModel.count > 0
                                     && app.allSendDestSet() && page.guestId !== ""
                            accent: Theme.success
                            onClicked: app.sendFilesToGuest()
                        }
                    }

                    /* Its own three-step stepper, same visual pattern as the
                       Replace -> Apply one above but naming this flow's real
                       steps: pack + upload to the server, the host pulling
                       it back down, then delivering it into the guest.
                       Entirely separate state (pushUploaded/pushPulled/
                       pushDelivered, pushProgressPercent) -- see the
                       properties' own comments in main.qml for why reusing
                       the Replace -> Apply flags broke the Apply button. */
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        visible: app.pushingNow || app.pushUploaded || app.pushStatus !== ""

                        Repeater {
                            model: [
                                { n: 1, label: "Upload to server",
                                  done: app.pushUploaded,
                                  active: app.pushingNow && !app.pushUploaded },
                                { n: 2, label: "Pull to host",
                                  done: app.pushPulled,
                                  active: app.pushingNow && app.pushUploaded && !app.pushPulled },
                                { n: 3, label: "Send to guest",
                                  done: app.pushDelivered,
                                  active: app.pushingNow && app.pushPulled && !app.pushDelivered }
                            ]

                            delegate: RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingTight

                                Rectangle {
                                    implicitWidth: 34; implicitHeight: 34
                                    radius: 17
                                    color: modelData.done ? Theme.success
                                         : modelData.active ? Theme.primary : Theme.surfaceVariant
                                    border.color: modelData.done || modelData.active
                                        ? "transparent" : Theme.outline
                                    border.width: 1

                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.done ? "✓" : String(modelData.n)
                                        color: modelData.done || modelData.active
                                            ? Theme.textOnAccent : Theme.textSecondary
                                        font.pixelSize: Theme.fontBody
                                        font.weight: Font.Bold
                                    }
                                }

                                Text {
                                    text: modelData.label
                                    color: modelData.done || modelData.active
                                        ? Theme.textPrimary : Theme.textSecondary
                                    font.pixelSize: Theme.fontBody
                                    font.weight: modelData.active ? Font.DemiBold : Font.Normal
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 2
                                    visible: modelData.n < 3
                                    color: modelData.done ? Theme.success : Theme.outline
                                }
                            }
                        }
                    }

                    ProgressBar {
                        Layout.fillWidth: true
                        visible: app.pushingNow || app.pushUploaded || app.pushStatus !== ""
                        from: 0; to: 100
                        value: app.pushProgressPercent
                        indeterminate: app.pushingNow && app.pushProgressPercent <= 0
                        Material.accent: (!app.pushingNow && app.pushDelivered) ? Theme.success : Theme.primary
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: app.pushStatus !== ""
                        text: app.pushStatus
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontSmall
                        wrapMode: Text.Wrap
                    }

                    Repeater {
                        model: sendModel

                        delegate: Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 56
                            radius: Theme.radiusSmall
                            color: Theme.surfaceSunken
                            border.color: model.dest.trim() === "" ? Theme.warning : Theme.outline
                            border.width: 1

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.spacingTight
                                anchors.rightMargin: Theme.spacingTight
                                spacing: Theme.spacingTight

                                Text {
                                    text: model.local
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontSmall
                                    elide: Text.ElideLeft
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 80
                                }

                                Text {
                                    text: "→"
                                    color: Theme.textDisabled
                                    font.pixelSize: Theme.fontBody
                                }

                                TextField {
                                    Layout.preferredWidth: 300
                                    Layout.preferredHeight: 40
                                    text: model.dest
                                    placeholderText: "/absolute/path/in/guest"
                                    font.family: Theme.monoFamily
                                    font.pixelSize: Theme.fontSmall
                                    Material.accent: Theme.primary
                                    onEditingFinished: {
                                        var d = text.trim();
                                        if (d !== "" && d[0] !== "/") d = "/" + d;
                                        sendModel.set(index, { local: model.local, dest: d });
                                    }
                                }

                                Button {
                                    text: "Browse guest"
                                    flat: true
                                    implicitHeight: 36
                                    font.pixelSize: Theme.fontSmall
                                    enabled: mqtt.connected && !app.otaBusy && page.guestId !== ""
                                    Material.foreground: Theme.primary
                                    onClicked: app.browseGuestFor(index)
                                }

                                ToolButton {
                                    text: "✕"
                                    font.pixelSize: Theme.fontBody
                                    enabled: !app.otaBusy
                                    Material.foreground: Theme.danger
                                    onClicked: sendModel.remove(index)
                                }
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: sendModel.count === 0
                        text: "No files queued. Add one and give it a destination path inside the guest."
                        color: Theme.textDisabled
                        font.pixelSize: Theme.fontSmall
                        wrapMode: Text.Wrap
                    }
                }
            }

            Item { Layout.preferredHeight: Theme.spacing }
        }
    }

    Dialog {
        id: confirmApply
        anchors.centerIn: Overlay.overlay
        width: 460
        modal: true
        title: "Apply update?"
        standardButtons: Dialog.Cancel | Dialog.Ok
        Material.background: Theme.surface
        onAccepted: app.doApply()

        Text {
            width: parent.width
            text: "The host kills " + page.guestId +
                  ", replaces the staged files in /guests/" + page.guestId +
                  ", and starts it again. The guest is offline while this runs."
            color: Theme.textPrimary
            font.pixelSize: Theme.fontBody
            wrapMode: Text.Wrap
        }
    }

    /* ---- save the current Send-files list as a named preset ---- */
    Dialog {
        id: savePresetDialog
        anchors.centerIn: Overlay.overlay
        width: 420
        modal: true
        title: "Save file list"
        standardButtons: Dialog.Cancel | Dialog.Ok
        Material.background: Theme.surface

        onOpened: { nameField.text = ""; nameField.forceActiveFocus() }
        onAccepted: app.saveSendPreset(nameField.text)

        ColumnLayout {
            width: parent.width
            spacing: Theme.spacingTight

            Text {
                Layout.fillWidth: true
                text: "Save the current " + sendModel.count +
                      " file(s) and their destinations under a name, to load again later."
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSmall
                wrapMode: Text.Wrap
            }

            TextField {
                id: nameField
                Layout.fillWidth: true
                Layout.preferredHeight: 42
                placeholderText: "e.g. \"motor firmware set\""
                font.pixelSize: Theme.fontBody
                Material.accent: Theme.primary
                onAccepted: savePresetDialog.accept()
            }
        }
    }

    /* ---- load (or delete) a previously saved preset ---- */
    Dialog {
        id: loadPresetDialog
        anchors.centerIn: Overlay.overlay
        width: 460
        height: 420
        modal: true
        title: "Load a saved file list"
        standardButtons: Dialog.Cancel
        Material.background: Theme.surface

        property var names: []
        onOpened: names = app.sendPresetNames()

        ColumnLayout {
            anchors.fill: parent
            spacing: Theme.spacingTight

            Text {
                Layout.fillWidth: true
                visible: loadPresetDialog.names.length === 0
                text: "No saved file lists yet — use Save next to Add file."
                color: Theme.textDisabled
                font.pixelSize: Theme.fontBody
                wrapMode: Text.Wrap
            }

            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: loadPresetDialog.names.length > 0
                model: loadPresetDialog.names
                spacing: 6
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Rectangle {
                    width: ListView.view.width
                    height: 46
                    radius: Theme.radiusSmall
                    color: Theme.surfaceSunken
                    border.color: Theme.outline
                    border.width: 1

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingTight
                        anchors.rightMargin: Theme.spacingTight
                        spacing: Theme.spacingTight

                        Text {
                            text: modelData
                            color: Theme.textPrimary
                            font.pixelSize: Theme.fontBody
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        Button {
                            text: "Load"
                            flat: true
                            implicitHeight: 34
                            font.pixelSize: Theme.fontSmall
                            Material.foreground: Theme.primary
                            onClicked: {
                                app.loadSendPreset(modelData);
                                loadPresetDialog.close();
                            }
                        }

                        ToolButton {
                            text: "✕"
                            font.pixelSize: Theme.fontBody
                            Material.foreground: Theme.danger
                            onClicked: {
                                app.deleteSendPreset(modelData);
                                loadPresetDialog.names = app.sendPresetNames();
                            }
                        }
                    }
                }
            }
        }
    }
}
