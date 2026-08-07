import QtQuick
import QtQuick.Controls
import App 1.0

/*
 * A filled action button with an explicit background.
 *
 * Not `Button { Material.accent: … ; highlighted: true }`, because the Material
 * attached properties propagate down the item tree: ApplicationWindow and the
 * ToolBar each set Material.background to the surface colour, every control
 * beneath them inherits it, and Material's button then paints that inherited
 * surface instead of the accent. The result was primary actions rendering as
 * bare text on white — the Connect button in the header looked like a label.
 *
 * Drawing the background here removes the whole question.
 */
Button {
    id: control

    property color accent: Theme.primary

    implicitHeight: Theme.controlHeight
    font.pixelSize: Theme.fontBody
    /* Enough padding that a label is never elided into "St…" the way the
       fixed-width row actions were. */
    leftPadding: 20
    rightPadding: 20

    contentItem: Text {
        text: control.text
        font: control.font
        color: control.enabled ? Theme.textOnAccent : Theme.textDisabled
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    background: Rectangle {
        radius: Theme.radiusSmall
        color: !control.enabled ? Theme.surfaceVariant
             : control.down     ? Qt.darker(control.accent, 1.2)
             : control.hovered  ? Qt.lighter(control.accent, 1.12)
                                : control.accent

        Behavior on color { ColorAnimation { duration: 90 } }
    }
}
