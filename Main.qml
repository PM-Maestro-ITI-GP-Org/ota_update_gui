import QtQuick
import QtQuick.Controls
import QtQuick.Window
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
    /* Maximized, not FullScreen: FullScreen drops the window manager's
       decorations (title bar, border, minimize/maximize/close buttons) on
       most window managers, leaving no on-screen way to unmaximize or quit.
       Maximized fills the screen the same way but keeps that chrome.

       Standalone only. Inside Maestro the shell owns the window, and a tab
       does not get an opinion about how the window is shown. */
    visibility: Window.Maximized
    title: qsTr("Hypervisor Management — OTA Update")
    color: Theme.background

    OtaAppPage {
        anchors.fill: parent
    }
}
