import QtQuick
import App 1.0

/*
 * A small state chip: running / stopped, a file's step, a connection state.
 *
 * `tone` picks the palette pair rather than the caller passing two colours, so
 * a state reads the same everywhere it appears.
 */
Rectangle {
    id: pill

    property string text: ""
    property string tone: "neutral"   /* success | danger | warning | primary | neutral */
    property int horizontalPadding: 12

    readonly property color fg: tone === "success" ? Theme.success
                              : tone === "danger"  ? Theme.danger
                              : tone === "warning" ? Theme.warning
                              : tone === "primary" ? Theme.primary
                                                   : Theme.textSecondary

    readonly property color bg: tone === "success" ? Theme.successSoft
                              : tone === "danger"  ? Theme.dangerSoft
                              : tone === "warning" ? Theme.warningSoft
                              : tone === "primary" ? Theme.primarySoft
                                                   : Theme.neutralSoft

    implicitWidth: label.implicitWidth + horizontalPadding * 2
    implicitHeight: 28
    radius: height / 2
    color: bg

    Text {
        id: label
        anchors.centerIn: parent
        text: pill.text
        color: pill.fg
        font.pixelSize: Theme.fontSmall
        font.weight: Font.DemiBold
    }
}
