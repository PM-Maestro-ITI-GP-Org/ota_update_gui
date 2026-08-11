#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QIcon>
#include <cstdio>
#include "mqttclient.h"
#include "control.h"

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    app.setApplicationName("OTA Update GUI");
    app.setOrganizationName("PM-Maestro");

    /*
     * Material, and set here rather than in the QML.
     *
     * QtQuick.Controls.Material's attached properties only theme controls that
     * the Material style actually instantiated, so the style has to be chosen
     * before the engine loads anything. The light/dark palette itself is
     * decided in Theme.qml and applied to the root window.
     */
    QQuickStyle::setStyle("Material");

    qmlRegisterType<MqttClient>("MqttClient", 1, 0, "MqttClient");

    /* Theme.qml as a singleton, so every page reads one palette instead of
       repeating hex literals. Theme.qml also carries `pragma Singleton`, which
       Qt requires to match this registration. */
    qmlRegisterSingletonType(QUrl("qrc:/Theme.qml"), "App", 1, 0, "Theme");

    /* Scripted control, off unless OTA_GUI_CONTROL names a port. See
       control.h -- every bug in this app so far has been a sequence bug, and
       those are minutes to reproduce by hand and seconds to script. */
    Control control;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("control", &control);

    /*
     * A QML error used to leave the process running with no window and no
     * message -- engine.load() returns void and nothing checked whether a root
     * object had been created, so a typo in the QML looked exactly like the app
     * silently refusing to start.
     */
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, []() {
        fprintf(stderr, "[GUI] FATAL: main.qml failed to load — see the QML errors above.\n");
        QCoreApplication::exit(1);
    }, Qt::QueuedConnection);

    engine.load(QUrl("qrc:/main.qml"));
    if (engine.rootObjects().isEmpty()) {
        fprintf(stderr, "[GUI] FATAL: no root object was created from main.qml.\n");
        return 1;
    }

    return app.exec();
}
