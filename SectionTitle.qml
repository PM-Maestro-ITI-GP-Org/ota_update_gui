import QtQuick
import QtQuick.Layouts
import PdM.Core

/* Heading + optional one-line explanation, used at the top of every panel. */
ColumnLayout {
    property string title: ""
    property string subtitle: ""

    spacing: 2

    Text {
        text: title
        color: Theme.textPrimary
        font.pixelSize: Theme.fontLarge
        font.weight: Font.DemiBold
        Layout.fillWidth: true
        elide: Text.ElideRight
    }

    Text {
        text: subtitle
        visible: subtitle !== ""
        color: Theme.textSecondary
        font.pixelSize: Theme.fontSmall
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }
}
