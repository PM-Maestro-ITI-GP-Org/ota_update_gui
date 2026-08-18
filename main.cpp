#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QtQml/qqmlextensionplugin.h>
#include <cstdio>

/*
 * The standalone entry point, and only that.
 *
 * Maestro does not compile this file -- see PROJECT_IS_TOP_LEVEL in
 * CMakeLists.txt -- so nothing here may be load-bearing for the app itself.
 * Everything that used to live here and matters to both builds has moved: the
 * qmlRegisterType() call is now QML_ELEMENT in mqttclient.h, the Theme
 * singleton comes from PdM.Core, and the `control` context property is a
 * QML_SINGLETON in control.h. That last one had to change: a context property
 * set here would never be set in the merged build, and the engine's root
 * context is shared by every app in the process.
 */

/* Static QML modules need an explicit import from the executable that links
   them. Without these the types resolve at build time and are missing at run
   time, which presents as "OtaAppPage is not a type" from a file that plainly
   imports the module. */
Q_IMPORT_QML_PLUGIN(PdM_CorePlugin)
Q_IMPORT_QML_PLUGIN(PdM_OtaPlugin)

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    /* Shared with Maestro on purpose, so a broker set in one is the broker the
       other uses -- PdM.Core's BrokerSettings persists it through QSettings. */
    app.setOrganizationName("PM-Maestro-ITI-GP-Org");
    app.setApplicationName("OTA Update GUI");

    /*
     * Material, and set here rather than in the QML.
     *
     * QtQuick.Controls.Material's attached properties only theme controls that
     * the Material style actually instantiated, so the style has to be chosen
     * before the engine loads anything. The light/dark palette itself is
     * decided in PdM.Core's Theme and applied to the root window.
     */
    QQuickStyle::setStyle("Material");

    QQmlApplicationEngine engine;

    /*
     * A QML error used to leave the process running with no window and no
     * message -- engine.load() returns void and nothing checked whether a root
     * object had been created, so a typo in the QML looked exactly like the app
     * silently refusing to start.
     */
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, []() {
        fprintf(stderr, "[GUI] FATAL: Main.qml failed to load — see the QML errors above.\n");
        QCoreApplication::exit(1);
    }, Qt::QueuedConnection);

    engine.loadFromModule("OtaGuiApp", "Main");

    return app.exec();
}
