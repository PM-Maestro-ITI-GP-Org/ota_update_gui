import QtQuick
import QtQuick.Controls
import PdM.Core
import PdM.Ota

/*
 * The standalone window, and nothing else.
 *
 * This file is not used when Maestro pulls the repository in -- the shell owns
 * the only ApplicationWindow in the merged process, and OtaAppPage goes
 * straight into a tab. What remains here is the handful of properties that only
 * mean something to a window.
 */
ApplicationWindow {
    id: appWindow

    visible: true

    /* Roomier by default: the old 1150x680 left the guest table and the OTA
       cards fighting for the same few hundred pixels. */
    width: 1440
    height: 920
    minimumWidth: 1080
    minimumHeight: 700
    title: qsTr("Hypervisor Management — OTA Update")
    color: Theme.background

    OtaAppPage {
        anchors.fill: parent
    }
}
