#include <QQmlEngine>
#include "control.h"
#include <QCoreApplication>
#include <cstdio>

namespace PdM {
namespace Ota {

Control *Control::instance()
{
    static Control control;
    return &control;
}

Control *Control::create(QQmlEngine *, QJSEngine *)
{
    Control *control = instance();
    /* The engine would otherwise take ownership of an object it did not
       allocate and destroy it at teardown. */
    QJSEngine::setObjectOwnership(control, QJSEngine::CppOwnership);
    return control;
}

Control::Control(QObject *parent) : QObject(parent)
{
    const QByteArray env = qgetenv("OTA_GUI_CONTROL");
    if (env.isEmpty())
        return;

    bool ok = false;
    const quint16 port = env.toUShort(&ok);
    if (!ok || port == 0) {
        fprintf(stderr, "[control] OTA_GUI_CONTROL=%s is not a port; ignoring\n",
                env.constData());
        return;
    }

    m_server = new QTcpServer(this);
    /* LocalHost, not Any. This runs UI actions with no authentication. */
    if (!m_server->listen(QHostAddress::LocalHost, port)) {
        fprintf(stderr, "[control] cannot listen on 127.0.0.1:%u: %s\n",
                port, qPrintable(m_server->errorString()));
        delete m_server;
        m_server = nullptr;
        return;
    }
    connect(m_server, &QTcpServer::newConnection, this, &Control::onConnection);
    fprintf(stderr, "[control] listening on 127.0.0.1:%u\n", port);
}

void Control::onConnection()
{
    QTcpSocket *sock = m_server->nextPendingConnection();
    if (!sock) return;

    connect(sock, &QTcpSocket::readyRead, this, [this, sock]() {
        while (sock->canReadLine()) {
            const QString line = QString::fromUtf8(sock->readLine()).trimmed();
            if (line.isEmpty()) continue;

            const QString verb = line.section(' ', 0, 0);
            const QString arg  = line.section(' ', 1).trimmed();

            if (verb == "state") {
                sock->write(m_state.toUtf8() + "\n");
            } else if (verb == "quit") {
                sock->write("bye\n");
                sock->flush();
                QCoreApplication::quit();
            } else {
                /* Direct, not queued: this already runs on the GUI thread, and
                   the reply should mean "the action has been performed" rather
                   than "it has been scheduled" -- a test that cannot tell those
                   apart cannot time anything. */
                emit command(verb, arg);
                sock->write("ok\n");
            }
            sock->flush();
        }
    });
    connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
}

} // namespace Ota
} // namespace PdM
