#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include "mqttclient.h"

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    qmlRegisterType<MqttClient>("MqttClient", 1, 0, "MqttClient");

    QQmlApplicationEngine engine;
    engine.load(QUrl("qrc:/main.qml"));

    return app.exec();
}
