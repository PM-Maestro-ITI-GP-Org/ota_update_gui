import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import App 1.0

/*
 * Timestamped, colour-coded activity log.
 *
 * Gains a level filter, a copy-to-clipboard and a clear button, and — the one
 * that actually mattered — it no longer force-scrolls to the bottom when the
 * user has scrolled up to read something. positionViewAtEnd() ran on every
 * single append, so during an OTA the log yanked itself back down several
 * times a second and could not be read at all.
 */
Item {
    id: logRoot

    property int maxEntries: 1000
    property string filter: "all"

    function append(type, text) {
        var atEnd = logView.atYEnd || logModel.count === 0;
        logModel.append({
            "type": type || "info",
            "time": Qt.formatTime(new Date(), "hh:mm:ss"),
            "text": text
        });
        while (logModel.count > maxEntries)
            logModel.remove(0);
        if (atEnd || autoScroll.checked)
            Qt.callLater(logView.positionViewAtEnd);
    }

    function clear() { logModel.clear() }

    function allText() {
        var out = [];
        for (var i = 0; i < logModel.count; ++i) {
            var e = logModel.get(i);
            out.push("[" + e.time + "] " + e.type.toUpperCase() + ": " + e.text);
        }
        return out.join("\n");
    }

    ListModel { id: logModel }

    /* The filter is applied in the delegate rather than by rebuilding a second
       model, so switching it never loses entries. */
    function visibleFor(type) {
        if (filter === "all") return true;
        if (filter === "problems") return type === "error" || type === "warning";
        return type === filter;
    }

    function toneFor(type) {
        return type === "error"   ? Theme.danger
             : type === "success" ? Theme.success
             : type === "warning" ? Theme.warning
                                  : Theme.textPrimary;
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingTight

            SectionTitle {
                Layout.fillWidth: true
                title: "Activity log"
                subtitle: logModel.count + " entries — everything the GUI sent and received"
            }

            ComboBox {
                id: filterBox
                Layout.preferredWidth: 190
                Layout.preferredHeight: Theme.controlHeight
                font.pixelSize: Theme.fontBody
                model: [
                    { label: "Everything",     value: "all" },
                    { label: "Problems only",  value: "problems" },
                    { label: "Errors",         value: "error" },
                    { label: "Successes",      value: "success" },
                    { label: "Info",           value: "info" }
                ]
                textRole: "label"
                valueRole: "value"
                onActivated: logRoot.filter = currentValue
                Material.foreground: Theme.textPrimary
            }

            CheckBox {
                id: autoScroll
                text: "Follow"
                checked: true
                font.pixelSize: Theme.fontBody
                Material.foreground: Theme.textPrimary
            }

            ToolButton {
                text: "Copy"
                font.pixelSize: Theme.fontBody
                Material.foreground: Theme.primary
                onClicked: {
                    copyHelper.text = logRoot.allText();
                    copyHelper.selectAll();
                    copyHelper.copy();
                    logRoot.append("info", "Log copied to the clipboard.");
                }
            }

            ToolButton {
                text: "Clear"
                font.pixelSize: Theme.fontBody
                Material.foreground: Theme.danger
                onClicked: logRoot.clear()
            }
        }

        /* Off-screen, only ever used as a clipboard shuttle for Copy. */
        TextEdit {
            id: copyHelper
            visible: false
            width: 0; height: 0
        }

        AppCard {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: Theme.surfaceSunken
            padding: Theme.spacingTight

            ListView {
                id: logView
                anchors.fill: parent
                model: logModel
                spacing: 2
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Item {
                    width: logView.width
                    height: visible ? row.implicitHeight + 8 : 0
                    visible: logRoot.visibleFor(model.type)

                    RowLayout {
                        id: row
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        spacing: Theme.spacingTight

                        Text {
                            text: model.time
                            color: Theme.textDisabled
                            font.family: Theme.monoFamily
                            font.pixelSize: Theme.fontSmall
                            Layout.alignment: Qt.AlignTop
                        }

                        Rectangle {
                            Layout.preferredWidth: 3
                            Layout.preferredHeight: msg.implicitHeight
                            radius: 1.5
                            color: logRoot.toneFor(model.type)
                            Layout.alignment: Qt.AlignTop
                        }

                        Text {
                            id: msg
                            text: model.text
                            color: model.type === "info" ? Theme.textPrimary
                                                         : logRoot.toneFor(model.type)
                            font.family: Theme.monoFamily
                            font.pixelSize: Theme.fontSmall
                            wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    text: "Nothing logged yet."
                    color: Theme.textDisabled
                    font.pixelSize: Theme.fontBody
                    visible: logModel.count === 0
                }
            }
        }
    }
}
