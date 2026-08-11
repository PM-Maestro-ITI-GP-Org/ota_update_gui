#ifndef CONTROL_H
#define CONTROL_H

#include <QObject>
#include <QTcpServer>
#include <QTcpSocket>
#include <QStringList>

/*
 * A test hook: drive the GUI from a script instead of by hand.
 *
 * Off unless OTA_GUI_CONTROL names a port, so a normal run is unaffected and
 * nothing listens on a user's machine by default. Bound to 127.0.0.1 only --
 * this executes UI actions with no authentication, and it has no business
 * being reachable from anywhere else.
 *
 * It exists because the bugs in this app have all been sequence bugs: switch
 * page, select a guest, switch back, do it while a reply is in flight. Those
 * are minutes of clicking to reproduce and seconds to script, and the ones
 * that need precise timing cannot be clicked at all.
 *
 * Line protocol, one command per line, one line of reply:
 *
 *     page <n>            switch to page index n
 *     guest <id|host>     select a guest in the Monitor ("host" = host only)
 *     refresh             force a Monitor poll
 *     cmd <text>          send a raw command to HMS
 *     state               dump the current UI state as JSON
 *     quit                exit the application
 */
class Control : public QObject
{
    Q_OBJECT
public:
    explicit Control(QObject *parent = nullptr);

    /* True when OTA_GUI_CONTROL was set and the port is listening. */
    bool active() const { return m_server != nullptr; }

    /* QML pushes its current state here so `state` has something to report.
       Called on every change worth observing, not polled. */
    Q_INVOKABLE void publishState(const QString &json) { m_state = json; }

signals:
    /* Wired up in main.qml. verb is the first word, arg the rest. */
    void command(const QString &verb, const QString &arg);

private slots:
    void onConnection();

private:
    QTcpServer *m_server = nullptr;
    QString     m_state = "{}";
};

#endif
