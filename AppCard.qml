import QtQuick
import PdM.Core

/*
 * A Material surface: rounded, hairline-outlined, with a soft elevation edge.
 * Every panel in the app is one of these, which is what stops the layout
 * drifting into a dozen slightly different card treatments.
 *
 * The elevation is drawn as two offset rounded rectangles behind the card
 * rather than with a MultiEffect drop shadow. A `layer.effect` needs the render
 * backend to run the effect's shader, and when it cannot the layered item
 * disappears completely — not just its shadow. That is exactly what happened
 * here: every card rendered as nothing but its contents, floating on the page
 * background. Two rectangles cost almost nothing, cannot fail, and at this
 * elevation are visually indistinguishable from a real blur.
 *
 * Children are added normally and fill the padded area.
 */
Item {
    id: card

    property int   elevation: 1
    property int   padding: Theme.spacing
    property color color: Theme.surface
    property color borderColor: Theme.outline
    property int   radius: Theme.radius

    default property alias content: inner.data

    /* Outer, softest step. */
    Rectangle {
        visible: card.elevation > 0
        anchors.fill: parent
        anchors.topMargin: card.elevation * 2
        anchors.leftMargin: -card.elevation
        anchors.rightMargin: -card.elevation
        anchors.bottomMargin: -card.elevation * 2
        radius: card.radius + card.elevation
        color: Qt.rgba(Theme.shadowColor.r, Theme.shadowColor.g,
                       Theme.shadowColor.b, Theme.shadowColor.a * 0.45)
    }

    /* Inner, tighter step. */
    Rectangle {
        visible: card.elevation > 0
        anchors.fill: parent
        anchors.topMargin: card.elevation
        anchors.bottomMargin: -card.elevation
        radius: card.radius
        color: Qt.rgba(Theme.shadowColor.r, Theme.shadowColor.g,
                       Theme.shadowColor.b, Theme.shadowColor.a * 0.7)
    }

    Rectangle {
        anchors.fill: parent
        color: card.color
        radius: card.radius
        border.color: card.borderColor
        border.width: 1
    }

    Item {
        id: inner
        anchors.fill: parent
        anchors.margins: card.padding
    }
}
