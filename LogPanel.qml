import QtQuick

/* Log panel: timestamped, colored log entries */
Rectangle {
    id: logRoot
    color: "#161b22"
    radius: 8
    border.color: "#30363d"
    border.width: 1
    clip: true

    function append(type, text) {
        logModel.append({ "type": type, "text": "[" + new Date().toLocaleTimeString() + "] " + text })
        logView.positionViewAtEnd()
        while (logModel.count > 500) logModel.remove(0)
    }

    ListModel { id: logModel }

    ListView {
        id: logView
        anchors.fill: parent
        anchors.margins: 8
        model: logModel
        spacing: 2
        clip: true

        delegate: Text {
            width: logView.width - 8
            text: model.text
            color: model.type === "error" ? "#f85149"
                 : model.type === "success" ? "#3fb950"
                 : model.type === "warning" ? "#d29922" : "#c9d1d9"
            font.family: "monospace"
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }
    }

    Text {
        anchors.centerIn: parent
        text: "(log empty)"
        color: "#8b949e"; font.pixelSize: 13
        visible: logModel.count === 0
    }
}
