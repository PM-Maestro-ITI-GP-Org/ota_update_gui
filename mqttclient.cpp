#include "mqttclient.h"
#include <QDateTime>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QStandardPaths>
#include <QCoreApplication>
#include <QThread>
#include <QElapsedTimer>
#include <cstring>
#include <functional>
#include <memory>

#define MQTT_BROKER "tcp://139.185.38.211:1883"
#define MQTT_USER "mqttuser"
#define MQTT_PASS "123456"

/*
 * Namespaced because ota_update_gui and motor_recorder_gui both define a class
 * called MqttClient, and in Maestro both are linked into one binary. Left in
 * the global namespace they collide at link time -- "multiple definition of
 * MqttClient::publishCommand" -- which is a link error rather than anything
 * subtle, but only appears once two apps are integrated, so it is worth
 * knowing before the third arrives.
 */
namespace PdM {
namespace Ota {


/* Exactly-once, matching HMS_MQTT_QOS in the host's mqtt_client.h. QoS 2 is a
 * four-part handshake per message, so on a ~145ms link each publish costs
 * about half a second of round trips -- paid for no duplicated commands and
 * no lost results. */
#define HMS_MQTT_QOS 2

#define CMD_TOPIC "hms/cmd"
#define STATUS_TOPIC "hms/status"

#define SERVER_USER_HOST "maxmaster@139.185.38.211"
#define SERVER_UPLOAD_DIR "/home/maxmaster/uploads"
#define SERVER_KEY_PATH (QDir::homePath() + "/.ssh/id_ed25519")

#ifdef HAVE_MQTT

/*
 * The callback context is the MqttClient itself.
 *
 * It used to be a heap-allocated MqttContext that was only deleted on the
 * failure paths -- so every successful connect leaked one, and since a dropped
 * connection reconnects by calling connectToBroker() again, a long session
 * leaked one per reconnect along with the previous MQTTClient handle, which
 * MQTTClient_create() overwrote without destroying.
 */
static void on_connection_lost(void *context, char *cause)
{
    auto *self = static_cast<MqttClient *>(context);
    fprintf(stderr, "[MQTT] Connection lost: %s\n", cause ? cause : "unknown");
    self->diag("LOST", QString("cause=%1").arg(cause ? cause : "(null)"));

    /*
     * This is where reconnection was dying. The old body called
     * scheduleReconnect() only `if (self->isConnected())`, and never cleared
     * the flag -- while scheduleReconnect() itself begins `if (m_connected)
     * return;`. So the one path into it was guarded on the very condition that
     * made it a no-op, and the GUI sat showing "Connected" forever after the
     * broker went away, with every command silently doing nothing.
     */
    QMetaObject::invokeMethod(self, [self]() {
        self->onConnectionLost();
    }, Qt::QueuedConnection);
}

/* Required once we publish above QoS 0: Paho hands back the delivery token
 * when the QoS 2 exchange finishes, and with no callback set the tokens are
 * never retired. Nothing here needs the token itself. */
static void on_delivered(void *context, MQTTClient_deliveryToken t)
{
    (void)context; (void)t;
}

static int on_message(void *context, char *topicName, int topicLen,
                      MQTTClient_message *message)
{
    auto *self = static_cast<MqttClient *>(context);
    int tlen = (topicLen > 0) ? topicLen : (topicName ? (int)strlen(topicName) : 0);
    QString topic = QString::fromUtf8(topicName, tlen);
    QString payload = QString::fromUtf8(
        static_cast<char *>(message->payload), message->payloadlen);
    self->diag("rx", QString("%1 bytes, state=%2")
                        .arg(message->payloadlen)
                        .arg(payload.section("\"state\":\"", 1, 1).section('"', 0, 0)));

    fprintf(stderr, "[MQTT] << %s : %s\n", qPrintable(topic), payload.left(160).toUtf8().constData());

    QMetaObject::invokeMethod(self, [self, topic, payload]() {
        if (topic == STATUS_TOPIC)
            self->handleStatusMessage(payload);
    }, Qt::QueuedConnection);

    MQTTClient_freeMessage(&message);
    MQTTClient_free(topicName);
    return 1;
}

#endif

MqttClient::MqttClient(QObject *parent)
    : QObject(parent), m_statusText("Initializing")
#ifdef HAVE_MQTT
    , m_client(nullptr)
#endif
    , m_cmdTimer(new QTimer(this))
{
    m_cmdTimer->setSingleShot(true);
    connect(m_cmdTimer, &QTimer::timeout, this, &MqttClient::onCmdTimeout);

    /*
     * Keepalive, restored -- and on the MQTT thread, which is what makes it
     * safe now.
     *
     * MQTTClient_yield() was removed earlier on the strength of half of its
     * documentation: "when implementing a single-threaded client". The other
     * half is "to allow processing of message retries AND TO SEND MQTT
     * KEEPALIVE PINGS", and with callbacks set nothing else was sending them.
     *
     * The broker enforces keepalive strictly -- measured against it, a client
     * that never pings is closed after about 1.5x its keepalive interval. The
     * GUI was being closed the same way: inbound simply stopped, publishes
     * went on returning rc=0 into a dead socket, and Paho took another ~76s to
     * notice and report it. Three drops in one run, 93.4 SECONDS apart to
     * within 20ms, which is the regularity of a timer rather than of a fault.
     *
     * The original objection to yield() was real: calling it from the GUI
     * thread put a second caller into a library that tolerates one. That is
     * gone now -- every Paho call, this one included, is marshalled onto the
     * MQTT thread, so there is still exactly one caller.
     *
     * 10s against a 30s keepalive: three chances to ping before the broker
     * gives up on us.
     */
    m_keepAlive = new QTimer(this);
    m_keepAlive->setInterval(10000);
    connect(m_keepAlive, &QTimer::timeout, this, [this]() {
        if (!m_connected) return;
        onMqttThread([this]() {
#ifdef HAVE_MQTT
            MQTTClient_yield();
            diag("keepalive", "yield returned");
#endif
        });
    });

    /* The one thread every Paho call runs on. Created before anything can
       publish, torn down last -- see the destructor. */
    m_mqttThread = new QThread();
    m_mqttWorker = new QObject();          /* no parent: it lives on that thread */
    m_mqttWorker->moveToThread(m_mqttThread);
    m_mqttThread->start();
    /*
     * MQTTClient_yield() used to be called here on a timer. It is gone, and
     * removing it is what stopped the Monitor page killing the connection.
     *
     * Paho's own header says what it is for:
     *
     *     "When implementing a single-threaded client, call this function
     *      periodically to allow processing of message retries and to send
     *      MQTT keepalive pings."
     *
     * This is not a single-threaded client. MQTTClient_setCallbacks() below
     * makes Paho run its own receive thread, so yield() from the GUI thread was
     * a second thread reading the same socket. A small packet arrives in one
     * read and survives that; a large one does not. hms/status carries both --
     * 40-byte heartbeats once a second, and a monitor_stats reply of tens of
     * kilobytes -- so the race was invisible until the Monitor page was opened
     * and then took the connection down every time:
     *
     *     [GUI] >> hms/cmd : stats
     *     [MQTT] Connection lost: unknown
     *
     * with the reply never arriving and an ~80s reconnect gap after it.
     */
    m_reconnectTimer = new QTimer(this);
    m_reconnectTimer->setSingleShot(true);
    m_reconnectTimer->setInterval(5000);
    connect(m_reconnectTimer, &QTimer::timeout, this, &MqttClient::attemptReconnect);

    /*
     * Host watchdog: if nothing is heard from HMS for this long, the board is
     * treated as gone.
     *
     * 3500ms against a 1000ms beat, so it takes three consecutive misses. Two
     * would trip on a single hiccup over the ~145ms link to the broker; much
     * more and switching the board off stops feeling immediate. Restarted on
     * every message, so the countdown only runs during actual silence.
     */
    m_hostWatchdog = new QTimer(this);
    m_hostWatchdog->setSingleShot(true);
    m_hostWatchdog->setInterval(3500);
    connect(m_hostWatchdog, &QTimer::timeout, this, [this]() {
        if (m_hostOnline)
            emitLog("Host stopped responding — no heartbeat for 3.5s.", "error");
        setHostOnline(false);
    });
}

static FILE       *g_diagFile = nullptr;
static QElapsedTimer g_diagClock;

void MqttClient::diag(const QString &tag, const QString &msg)
{
    if (!g_diagClock.isValid()) {
        g_diagClock.start();
        const QString path = QDir::homePath() + "/ota_gui_diag.log";
        g_diagFile = fopen(path.toUtf8().constData(), "w");
        fprintf(stderr, "[diag] tracing to %s\n", qPrintable(path));
    }
    const QString line = QString("%1  t%2  %3  %4")
        .arg(g_diagClock.elapsed(), 8)
        .arg((quintptr)QThread::currentThreadId(), 6, 16, QLatin1Char('0'))
        .arg(tag, -14)
        .arg(msg);
    fprintf(stderr, "[diag] %s\n", qPrintable(line));
    if (g_diagFile) { fprintf(g_diagFile, "%s\n", qPrintable(line)); fflush(g_diagFile); }
}

bool MqttClient::hostOnline() const { return m_hostOnline; }

void MqttClient::setHostOnline(bool online)
{
    if (online) {
        /* Every message counts as a sign of life, so the timer is rearmed even
           when the state itself has not changed. */
        m_hostWatchdog->start();
    } else {
        m_hostWatchdog->stop();
    }

    if (m_hostOnline == online) return;

    m_hostOnline = online;
    if (online) emitLog("Host is online.", "success");
    emit hostOnlineChanged();
}

/* Run fn on the MQTT thread. Queued, so the caller never blocks -- which is
   the point for connect(), and harmless for publish(). */
void MqttClient::onMqttThread(std::function<void()> fn)
{
    if (!m_mqttWorker) { fn(); return; }
    QMetaObject::invokeMethod(m_mqttWorker, std::move(fn), Qt::QueuedConnection);
}

MqttClient::~MqttClient()
{
    /* Blocking, deliberately: the handle must be destroyed on the thread that
       owns it, and before that thread goes away. */
    if (m_mqttWorker && m_mqttThread && m_mqttThread->isRunning()) {
        QMetaObject::invokeMethod(m_mqttWorker, [this]() { teardownClient(); },
                                  Qt::BlockingQueuedConnection);
        m_mqttThread->quit();
        m_mqttThread->wait(3000);
    } else {
        teardownClient();
    }
    delete m_mqttWorker;
    delete m_mqttThread;
}

/* Drop the Paho handle if there is one. Safe to call when there is not. */
void MqttClient::teardownClient()
{
#ifdef HAVE_MQTT
    if (m_client) {
        if (MQTTClient_isConnected(m_client))
            MQTTClient_disconnect(m_client, 1000);
        MQTTClient_setCallbacks(m_client, nullptr, nullptr, nullptr, nullptr);
        MQTTClient_destroy(&m_client);
        m_client = nullptr;
    }
#endif
}

void MqttClient::onConnectionLost()
{
    m_keepAlive->stop();
    diag("link", "onConnectionLost — clearing pending, scheduling reconnect");
    /* Clear the flag first: scheduleReconnect() refuses to do anything while
       it is still set, which is what stopped the GUI ever coming back. */
    setConnected(false);
    setStatusText("Connection lost — reconnecting...");
    m_cmdTimer->stop();
    m_pendingCmd.clear();
    emitLog("Connection to broker lost — will reconnect.", "warning");
    scheduleReconnect();
}

bool MqttClient::isConnected() const { return m_connected; }

QString MqttClient::statusText() const { return m_statusText; }

QString MqttClient::broker() const { return MQTT_BROKER; }

QString MqttClient::serverUserHost() const { return SERVER_USER_HOST; }

QString MqttClient::homePath() const { return QDir::homePath(); }

QString MqttClient::serverUploadDir() const { return SERVER_UPLOAD_DIR; }

void MqttClient::setConnected(bool c)
{
    if (m_connected != c) {
        m_connected = c;

        /* Losing the broker means losing the only channel that could tell us
           anything about the board. Whatever it was doing, we no longer know
           -- so stop claiming it is online rather than leaving a stale green
           light on screen. */
        if (!c) setHostOnline(false);

        emit connectedChanged();
    }
}

void MqttClient::setStatusText(const QString &t)
{
    if (m_statusText != t) {
        m_statusText = t;
        emit statusTextChanged();
    }
}

void MqttClient::emitLog(const QString &text, const QString &type)
{
    emit logMessage(text, type);
}

void MqttClient::connectToBroker()
{
#ifdef HAVE_MQTT
    m_reconnectTimer->stop();
    setStatusText("Connecting...");
    fprintf(stderr, "[GUI] Connecting to MQTT broker %s...\n", MQTT_BROKER);
    emitLog("Connecting to MQTT broker " MQTT_BROKER " ...", "info");

    /* Reconnecting calls straight back into here, so an old handle from the
       previous attempt has to go before MQTTClient_create() overwrites the
       member and loses it. */
    /*
     * Paho on the MQTT thread; every Qt touch marshalled back.
     *
     * MQTTClient_connect blocks for up to connectTimeout (5s), so on the GUI
     * thread it froze the app on each reconnect attempt. But the results have
     * to come home: QTimer cannot be started or stopped from a thread that
     * does not own it, and scheduleReconnect()/refreshGuests() both do exactly
     * that. Hence the split -- Paho below, Qt in the continuation.
     */
    onMqttThread([this]() {
        teardownClient();

        const QString clientId =
            "ota_gui_" + QString::number(QDateTime::currentMSecsSinceEpoch());
        const QByteArray clientIdUtf8 = clientId.toUtf8();

        int rc = MQTTClient_create(&m_client, MQTT_BROKER, clientIdUtf8.constData(),
                                   MQTTCLIENT_PERSISTENCE_NONE, nullptr);
        if (rc != MQTTCLIENT_SUCCESS) {
            fprintf(stderr, "[GUI] MQTTClient_create failed: %d\n", rc);
            m_client = nullptr;
            QMetaObject::invokeMethod(this, [this, rc]() {
                emitLog(QString("Failed to create MQTT client (%1).").arg(rc), "error");
                setStatusText("Create failed");
                scheduleReconnect();
            }, Qt::QueuedConnection);
            return;
        }

        MQTTClient_connectOptions opts = MQTTClient_connectOptions_initializer;
        opts.connectTimeout = 5;
        /*
         * 0 = no keepalive, and this is the fix, not a shortcut.
         *
         * The broker enforces keepalive strictly: a raw client that never
         * pings is closed after about 1.5x its interval -- measured, 51s
         * against a declared 30. This client was being closed exactly that
         * way, on a metronome: inbound stopped dead, publishes carried on
         * returning rc=0 into a socket nobody was listening to, and Paho took
         * a further ~76s to work out it had been hung up on. Three drops in
         * one run, 93.4s apart to within 20ms.
         *
         * Restoring MQTTClient_yield() on the MQTT thread did not stop it, so
         * whatever the documentation means by "sends MQTT keepalive pings", it
         * is not reaching the wire from this configuration.
         *
         * With 0 the broker is told not to expect pings and stops closing us
         * for their absence. What it costs is the broker's own liveness check;
         * a genuinely dead link is then noticed by the host heartbeat watchdog
         * instead, which fires after 3.5s of silence -- twenty times faster
         * than the ~76s Paho was taking anyway.
         */
        opts.keepAliveInterval = 0;
        opts.cleansession = 1;
        opts.username = MQTT_USER;
        opts.password = MQTT_PASS;

        MQTTClient_setCallbacks(m_client, this, on_connection_lost, on_message, on_delivered);

        rc = MQTTClient_connect(m_client, &opts);
        if (rc != MQTTCLIENT_SUCCESS) {
            fprintf(stderr, "[GUI] MQTT connection failed (error %d)\n", rc);
            teardownClient();
            QMetaObject::invokeMethod(this, [this, rc]() {
                setConnected(false);
                setStatusText("Connection failed");
                emitLog(QString("MQTT connection failed (error %1) — retrying.").arg(rc), "error");
                scheduleReconnect();
            }, Qt::QueuedConnection);
            return;
        }

        /*
         * QoS 1 inbound, deliberately, while commands still go out at QoS 2.
         *
         * Subscribing at QoS 2 made the Monitor page kill the connection.
         * Measured against the live broker, same board, same command, only
         * the subscription QoS differing:
         *
         *     QoS 2 -> monitor_stats received 0, connection lost 1
         *     QoS 1 -> monitor_stats received 1, connection lost 0
         *
         * Nothing is given up: cleansession is 1 and there is no persistence,
         * so no inbound QoS 2 state survives a reconnect anyway, and every
         * message on this topic is an idempotent snapshot.
         *
         * Checked, too. An unchecked subscribe that fails gives a GUI showing
         * "Connected" with a green light and no message ever arriving.
         */
        int src = MQTTClient_subscribe(m_client, STATUS_TOPIC, 1);
        if (src != MQTTCLIENT_SUCCESS) {
            fprintf(stderr, "[GUI] subscribe to %s failed: %d\n", STATUS_TOPIC, src);
            teardownClient();
            QMetaObject::invokeMethod(this, [this, src]() {
                setConnected(false);
                setStatusText("Subscribe failed");
                emitLog(QString("Subscribed to nothing — broker refused (error %1). "
                                "Reconnecting.").arg(src), "error");
                scheduleReconnect();
            }, Qt::QueuedConnection);
            return;
        }

        fprintf(stderr, "[GUI] Connected to broker at " MQTT_BROKER "\n");
        QMetaObject::invokeMethod(this, [this]() {
            m_reconnectTimer->stop();
            m_reconnectAttempts = 0;
            m_keepAlive->start();
            setConnected(true);
            setStatusText("Connected");
            emitLog("Connected to broker.", "success");
            refreshGuests();
        }, Qt::QueuedConnection);
    });

#else
    setStatusText("Demo mode");
    emitLog("MQTT not available — running in demo mode.", "warning");
#endif
}

void MqttClient::disconnectFromBroker()
{
    m_reconnectTimer->stop();
    m_reconnectAttempts = 0;
    teardownClient();
    m_cmdTimer->stop();
    m_pendingCmd.clear();
    setConnected(false);
    setStatusText("Disconnected");
    emitLog("Disconnected from broker.", "warning");
}

void MqttClient::scheduleReconnect()
{
    if (m_connected)
        return;
    if (m_reconnectTimer->isActive())
        return;

    m_reconnectAttempts++;
    /* Back off 2s, 4s, 8s ... capped at 30s, so a broker that is down for a
       while is not hammered with a connect attempt every 5 seconds for hours. */
    int delayMs = qMin(2000 * (1 << qMin(m_reconnectAttempts - 1, 4)), 30000);
    fprintf(stderr, "[GUI] Reconnect attempt %d in %d ms\n", m_reconnectAttempts, delayMs);
    setStatusText(QString("Reconnecting in %1s...").arg(delayMs / 1000));
    m_reconnectTimer->start(delayMs);
}

void MqttClient::attemptReconnect()
{
    if (m_connected)
        return;
    emitLog("Attempting to reconnect to broker...", "info");
    connectToBroker();
}

void MqttClient::publishCommand(const QString &cmd)
{
#ifdef HAVE_MQTT
    if (!m_connected || !m_client) {
        emitLog("Cannot send command: not connected.", "error");
        return;
    }
    QByteArray utf8 = cmd.toUtf8();
    fprintf(stderr, "[GUI] >> %s : %s\n", CMD_TOPIC, cmd.toUtf8().constData());

    /* Checked. A dropped publish is indistinguishable from HMS ignoring us:
       the command never leaves, the timeout below fires, and onCmdTimeout()
       then blames HMS for still starting up. MQTTCLIENT_MAX_MESSAGES_INFLIGHT
       is a documented return here at QoS 2, so this is not hypothetical. */
    /* Pending state is GUI-thread state, set here; the wire call goes to the
       MQTT thread. Opening the Monitor publishes while a reply is being
       delivered, and doing both on the same handle from two threads is what
       killed the client outright. */
    m_pendingCmd = cmd;
    m_cmdTimer->start(m_timeoutSec * 1000);

    diag("publish", QString("cmd='%1' pending='%2'").arg(cmd, m_pendingCmd));

    onMqttThread([this, utf8, cmd]() {
        if (!m_client) { diag("publish", "NO CLIENT — dropped"); return; }
        diag("publish", QString("calling MQTTClient_publish for '%1'").arg(cmd));
        int rc = MQTTClient_publish(m_client, CMD_TOPIC, utf8.size(), utf8.constData(),
                                    HMS_MQTT_QOS, false, nullptr);
        diag("publish", QString("returned rc=%1 for '%2'").arg(rc).arg(cmd));
        if (rc == MQTTCLIENT_SUCCESS) return;

        fprintf(stderr, "[GUI] publish of '%s' failed: %d\n",
                cmd.toUtf8().constData(), rc);
        QMetaObject::invokeMethod(this, [this, cmd, rc]() {
            m_cmdTimer->stop();
            if (m_pendingCmd == cmd) m_pendingCmd.clear();
            emitLog(QString("Could not send '%1' — broker returned %2.")
                        .arg(cmd.section(' ', 0, 0)).arg(rc), "error");
        }, Qt::QueuedConnection);
    });
#else
    (void)cmd;
#endif
}

void MqttClient::onCmdTimeout()
{
    diag("cmd-timeout", QString("pending='%1'").arg(m_pendingCmd));
    fprintf(stderr, "[GUI] TIMEOUT: no response for '%s'\n", m_pendingCmd.toUtf8().constData());
    /* Not "check that hms is running". The usual cause is that it *is*
       running and has no network yet: hms starts early in the board's boot
       and the wifi lease lands afterwards, so there is a window where it
       retries the broker and answers nothing. Saying the wrong thing sends
       people to look at the wrong end. */
    emitLog(QString("No answer to '%1' after %2s. HMS may still be starting — "
                    "it connects to the broker only once the board has a "
                    "network. Retry in a moment.")
                .arg(m_pendingCmd.section(' ', 0, 0)).arg(m_timeoutSec),
            "warning");
    m_pendingCmd.clear();
}

void MqttClient::refreshGuests()
{
    publishCommand("list");
    emitLog("Requesting guest list...", "info");
}

void MqttClient::startGuest(const QString &id, const QString &ip)
{
    QString cmd = "start " + id;
    if (!ip.isEmpty())
        cmd += " " + ip;
    publishCommand(cmd);
    emitLog("Sent START for guest '" + id + "'" + (ip.isEmpty() ? "" : " with IP " + ip), "info");
}

void MqttClient::killGuest(const QString &id)
{
    publishCommand("kill " + id);
    emitLog("Sent KILL for guest '" + id + "'", "info");
}

void MqttClient::guestInfo(const QString &id)
{
    publishCommand("info " + id);
    emitLog("Requesting info for guest '" + id + "'...", "info");
}

void MqttClient::execCommand(const QString &id, const QString &command)
{
    publishCommand("exec " + id + " " + command);
    emitLog("Sent EXEC on guest '" + id + "': " + command, "info");
}

void MqttClient::publishNoWait(const QString &cmd)
{
#ifdef HAVE_MQTT
    diag("publish-nw", QString("requested '%1'").arg(cmd));
    if (!m_connected || !m_client) {
        emitLog("Cannot send command: not connected.", "error");
        return;
    }
    QByteArray utf8 = cmd.toUtf8();
    fprintf(stderr, "[GUI] >> %s : %s\n", CMD_TOPIC, cmd.toUtf8().constData());

    /*
     * On the MQTT thread, exactly like publishCommand.
     *
     * This called MQTTClient_publish straight from the GUI thread, and it is
     * the ONLY caller path the Monitor uses -- guestStats() goes through here,
     * everything else goes through publishCommand(). So moving publishCommand
     * to its own thread fixed every feature except the one that was broken.
     *
     * The trace says it plainly. Selecting a guest:
     *
     *     12716  monitor  setGuest('guest-1')
     *     12717  monitor  refreshNow('guest-1')
     *            >> hms/cmd : stats guest-1
     *     27851  monitor  link down
     *
     * Fifteen seconds with no output from ANY thread -- not the GUI, not the
     * MQTT worker, and not Paho's receive thread, which had been logging a
     * heartbeat every second right up to that line. The GUI thread went into
     * Paho while Paho's own thread was delivering, and took the whole client
     * down with it.
     */
    onMqttThread([this, utf8, cmd]() {
        if (!m_client) { diag("publish-nw", "NO CLIENT — dropped"); return; }
        diag("publish-nw", QString("calling MQTTClient_publish for '%1'").arg(cmd));
        int rc = MQTTClient_publish(m_client, CMD_TOPIC, utf8.size(), utf8.constData(),
                                    HMS_MQTT_QOS, false, nullptr);
        diag("publish-nw", QString("returned rc=%1 for '%2'").arg(rc).arg(cmd));
        if (rc != MQTTCLIENT_SUCCESS)
            fprintf(stderr, "[GUI] publish of '%s' failed: %d\n",
                    cmd.toUtf8().constData(), rc);
    });
#else
    (void)cmd;
#endif
}

void MqttClient::guestStats(const QString &id)
{
    QString cmd = id.isEmpty() ? "stats" : "stats " + id;
    /* No timeout tracking: polling every few seconds must not re-arm the
       command timeout timer (responses can legitimately take longer than
       the 15 s command timeout when HMS is busy). The QML side guards
       against pileup with an in-flight flag + its own watchdog. */
    publishNoWait(cmd);
    emitLog("Requesting system stats" + (id.isEmpty() ? QString() : " for '" + id + "'") + "...", "info");
}

/* ---- Interactive shell (HMS shell.c) ---------------------------------- */

void MqttClient::shellOpen(const QString &guestId)
{
    if (guestId.isEmpty()) { emitLog("Select a guest first.", "error"); return; }
    publishCommand("shellopen " + guestId);
    emitLog("Opening interactive shell on '" + guestId + "'...", "info");
}

void MqttClient::shellWrite(const QString &guestId, const QString &data)
{
    if (guestId.isEmpty()) return;
    /* No timeout tracking: the reply is a stream of shell_out chunks, not a
       single response, and re-arming the command timer on every keystroke
       would fire spuriously the moment the user paused. */
    publishNoWait("shellwrite " + guestId + " " + data);
}

void MqttClient::shellClose(const QString &guestId)
{
    if (guestId.isEmpty()) return;
    publishCommand("shellclose " + guestId);
    emitLog("Closing shell on '" + guestId + "'.", "info");
}

/* ---- addfile / addguest (HMS ota.c) ----------------------------------- */

void MqttClient::addFileToGuest(const QString &guestId, const QString &serverPath)
{
    if (guestId.isEmpty() || serverPath.isEmpty()) {
        emitLog("Add file needs a guest and a staged server path.", "error");
        return;
    }
    publishCommand("addfile " + guestId + " " + serverPath);
    emitLog("Adding " + serverPath + " to guest '" + guestId + "'...", "info");
}

void MqttClient::addGuest(const QString &guestId, const QString &ifsServerPath,
                          const QString &confServerPath, const QString &ip)
{
    if (guestId.isEmpty() || ifsServerPath.isEmpty() || confServerPath.isEmpty()) {
        emitLog("New guest needs an id, a boot image and a qvmconf.", "error");
        return;
    }
    QString cmd = "addguest " + guestId + " " + ifsServerPath + " " + confServerPath;
    if (!ip.isEmpty()) cmd += " " + ip;
    publishCommand(cmd);
    emitLog("Creating guest '" + guestId + "' on the host...", "info");
}

void MqttClient::ping()
{
    publishCommand("ping");
    emitLog("Ping...", "info");
}

void MqttClient::guestFiles(const QString &id)
{
    if (id.isEmpty()) {
        emitLog("Select a guest to list its partitions.", "error");
        return;
    }
    publishCommand("files " + id);
    emitLog("Requesting partition list for '" + id + "'...", "info");
}

void MqttClient::handleStatusMessage(const QString &payload)
{
    diag("dispatch", QString("%1 chars").arg(payload.size()));
    QJsonDocument doc = QJsonDocument::fromJson(payload.toUtf8());
    QJsonObject obj = doc.object();
    QString state = obj.value("state").toString();

    auto clearIfPending = [this](const QString &cmdPrefix) {
        if (m_pendingCmd.startsWith(cmdPrefix)) {
            m_cmdTimer->stop();
            m_pendingCmd.clear();
        }
    };
    /* Also clears any OTA-related pending (apply, fetch, ota). */
    auto clearIfOta = [this]() {
        if (m_pendingCmd.startsWith("apply") || m_pendingCmd.startsWith("fetch")
            || m_pendingCmd.startsWith("ota")) {
            m_cmdTimer->stop();
            m_pendingCmd.clear();
        }
    };

    /* Liveness first, and it never touches m_pendingCmd: a beat is not a reply
       to anything, so letting it clear a pending command would make an
       unrelated timeout disappear once a second. */
    if (state == "host") {
        const bool online = obj.value("online").toBool(false);
        setHostOnline(online);
        if (online) emit heartbeat();
        return;
    }

    /* Anything at all from HMS proves it is alive, so treat it as a beat. This
       keeps the light steady through a slow `ota` or a big `stats` even if a
       beat or two is lost behind the traffic. */
    setHostOnline(true);

    if (state == "guest_list") {
        clearIfPending("list");
        emit guestListReceived(payload);
    } else if (state == "guest_info") {
        clearIfPending("info");
        emit guestInfoReceived(payload);
    } else if (state == "result") {
        QString cmd = obj.value("cmd").toString();
        QString guest = obj.value("guest").toString();
        bool ok = obj.value("success").toBool();
        QString msg = obj.value("msg").toString();
        clearIfPending("start");
        clearIfPending("kill");
        emit cmdResult(cmd, guest, ok, msg);
        emitLog(QString("[%1] %2 — %3").arg(guest.isEmpty() ? cmd : guest, ok ? "OK" : "FAILED", msg),
                ok ? "success" : "error");
    } else if (state == "exec_result") {
        clearIfPending("exec");
        emit execOutput(obj.value("guest").toString(), obj.value("output").toString());
    } else if (state == "monitor_stats") {
        clearIfPending("stats");
        emit guestStatsReceived(payload);
    } else if (state == "ota_progress") {
        clearIfOta();
        emit otaProgress(obj.value("guest").toString(),
                         obj.value("stage").toString(),
                         obj.value("progress").toInt(),
                         obj.value("msg").toString());
    } else if (state == "ota_result") {
        clearIfOta();
        emit otaResult(obj.value("guest").toString(),
                       obj.value("success").toBool(),
                       obj.value("msg").toString());
        emitLog(QString("OTA %1: %2").arg(obj.value("success").toBool() ? "OK" : "FAILED",
                                          obj.value("msg").toString()),
                obj.value("success").toBool() ? "success" : "error");
    } else if (state == "guest_files") {
        clearIfPending("files");
        emit guestFilesReceived(payload);
    } else if (state == "shell_opened") {
        clearIfPending("shellopen");
        emit shellOpened(obj.value("guest").toString(), obj.value("msg").toString());
    } else if (state == "shell_out") {
        emit shellOutput(obj.value("guest").toString(), obj.value("data").toString());
    } else if (state == "shell_closed") {
        clearIfPending("shellclose");
        emit shellClosed(obj.value("guest").toString(), obj.value("msg").toString());
    } else if (state == "addfile_result") {
        clearIfPending("addfile");
        emit addFileResult(obj.value("guest").toString(),
                           obj.value("success").toBool(),
                           obj.value("msg").toString());
        emitLog("Add file: " + obj.value("msg").toString(),
                obj.value("success").toBool() ? "success" : "error");
    } else if (state == "addguest_result") {
        clearIfPending("addguest");
        emit addGuestResult(obj.value("guest").toString(),
                            obj.value("success").toBool(),
                            obj.value("msg").toString());
        emitLog("Add guest: " + obj.value("msg").toString(),
                obj.value("success").toBool() ? "success" : "error");
    } else if (state == "pong") {
        clearIfPending("ping");
        emit pongReceived();
        emitLog("Pong — HMS is alive.", "success");
    } else if (!state.isEmpty()) {
        /* Unknown states were dropped in silence, which is how a protocol
           drifts apart without anyone noticing. */
        fprintf(stderr, "[GUI] unhandled status state '%s'\n", qPrintable(state));
    } else {
        emitLog("Ignored a malformed status message from HMS.", "warning");
    }
}

/*
 * Upload the local package to the server with SCP. Once the upload
 * completes, tell HMS to pull it from the server and apply it.
 */
void MqttClient::uploadAndDeployOta(const QString &guestId, const QString &localFilePath)
{
    QFileInfo fi(localFilePath);
    if (!fi.exists()) {
        emitLog("File not found: " + localFilePath, "error");
        return;
    }
    if (guestId.isEmpty()) {
        emitLog("Select a guest to update first.", "error");
        return;
    }
    if (!m_connected) {
        emitLog("Cannot deploy: not connected to broker.", "error");
        return;
    }

    QString remotePath = QString(SERVER_UPLOAD_DIR) + "/" + fi.fileName();
    emitLog("Uploading " + localFilePath + " to server " SERVER_USER_HOST " ...", "info");

    struct UploadState {
        QProcess *proc = nullptr;
        QProcess *statProc = nullptr;
        qint64 localSize = 0;
        int lastPct = -1;
        QString guestId;
        QString remotePath;
        QString localFilePath;
    };

    /* shared_ptr, not new/delete. The state was deleted at the end of the
       proc-finished handler while the statProc handler still captured it by
       raw pointer, so a stat that landed after the upload finished read freed
       memory. startScpUpload() below already did it this way; this function
       had not been brought along. */
    auto up = std::make_shared<UploadState>();
    up->proc = new QProcess(this);
    up->statProc = new QProcess(this);
    up->localSize = fi.size();
    up->guestId = guestId;
    up->remotePath = remotePath;
    up->localFilePath = localFilePath;

    QStringList args = {
        "-C",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=10",
        "-i", SERVER_KEY_PATH,
        localFilePath,
        QString(SERVER_USER_HOST) + ":" + remotePath
    };
    fprintf(stderr, "[GUI] scp %s\n", qPrintable(args.join(' ')));

    /* Poll the server for the partial upload size and report progress. */
    connect(up->statProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this, up](int code, QProcess::ExitStatus) {
        if (code == 0 && up->proc->state() == QProcess::Running) {
            qint64 remoteSize = QString::fromUtf8(up->statProc->readAllStandardOutput()).trimmed().toLongLong();
            if (remoteSize > 0 && up->localSize > 0) {
                int pct = (int)(remoteSize * 100 / up->localSize);
                if (pct > 100) pct = 100;
                if (pct != up->lastPct) {
                    up->lastPct = pct;
                    emit uploadProgress(pct, QFileInfo(up->localFilePath).fileName());
                    emitLog("Upload progress: " + QString::number(pct) + "%", "info");
                }
            }
        }
    });

    auto *progressTimer = new QTimer(this);
    connect(progressTimer, &QTimer::timeout, this, [this, up]() {
        if (up->proc->state() != QProcess::Running) return;
        if (up->statProc->state() == QProcess::Running) return;
        QStringList sizeArgs = {
            "-i", SERVER_KEY_PATH,
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=5",
            SERVER_USER_HOST,
            "stat -c %s " + up->remotePath
        };
        up->statProc->start("ssh", sizeArgs);
    });
    progressTimer->start(3000);

    connect(up->proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this, up, progressTimer](int exitCode, QProcess::ExitStatus) {
        progressTimer->stop();
        progressTimer->deleteLater();
        if (exitCode == 0) {
            emit uploadProgress(100, QFileInfo(up->localFilePath).fileName());
            emitLog("Upload complete (" + QString::number(QFileInfo(up->localFilePath).size() / 1024) + " KB on server).", "success");
            publishOtaCmd(up->guestId, up->remotePath);
        } else {
            QString err = QString::fromUtf8(up->proc->readAllStandardError()).trimmed();
            emitLog("SCP upload failed (exit=" + QString::number(exitCode) + ") " + err, "error");
            emit uploadFailed(QFileInfo(up->localFilePath).fileName(), err);
        }
        if (up->statProc->state() != QProcess::NotRunning) {
            up->statProc->kill();
            up->statProc->waitForFinished(2000);
        }
        up->statProc->deleteLater();
        up->proc->deleteLater();
    });

    /* If scp is missing from PATH, finished() never fires -- the timer would
       poll forever and the caller would never learn the upload failed. */
    connect(up->proc, &QProcess::errorOccurred, this,
            [this, up, progressTimer](QProcess::ProcessError e) {
        if (e != QProcess::FailedToStart) return;
        progressTimer->stop();
        progressTimer->deleteLater();
        emitLog("Could not run 'scp' — is OpenSSH installed and on PATH?", "error");
        emit uploadFailed(QFileInfo(up->localFilePath).fileName(), "scp not found");
    });

    up->proc->start("scp", args);
}

void MqttClient::publishOtaCmd(const QString &guestId, const QString &remotePath)
{
    QString cmd = "ota " + guestId + " " + remotePath;
    publishCommand(cmd);
    emitLog("Sent OTA deploy for guest '" + guestId + "': " + remotePath, "info");
}

/*
 * Upload a single local file to the server's uploads directory WITHOUT deploying.
 * Used by the new per-partition OTA flow: each chosen file is staged first, then a
 * single "apply" command replaces the on-disk files and restarts the guest.
 */
void MqttClient::uploadOtaFile(const QString &localFilePath, const QString &serverName)
{
    QString name = serverName.isEmpty() ? QFileInfo(localFilePath).fileName() : serverName;
    startScpUpload(localFilePath, QString(SERVER_UPLOAD_DIR) + "/" + name, true);
}

void MqttClient::uploadGenericFile(const QString &localFilePath, const QString &serverName)
{
    QString name = serverName.isEmpty() ? QFileInfo(localFilePath).fileName() : serverName;
    startScpUpload(localFilePath, QString(SERVER_UPLOAD_DIR) + "/" + name, false);
}

/* Shared SCP upload with progress polling + stall watchdog + retries.
 * On success emits fileStaged (ota=true) or genericUploaded (ota=false). */
void MqttClient::startScpUpload(const QString &localFilePath, const QString &remotePath, bool ota)
{
    QFileInfo fi(localFilePath);
    if (!fi.exists()) {
        emitLog("File not found: " + localFilePath, "error");
        return;
    }
    if (!m_connected) {
        emitLog("Cannot stage file: not connected to broker.", "error");
        return;
    }

    struct UploadState {
        QProcess *proc = nullptr;
        QProcess *statProc = nullptr;
        QTimer *watchdog = nullptr;
        qint64 localSize = 0;
        qint64 lastSize = 0;
        int lastPct = -1;
        int retries = 0;
        bool retrying = false;
        bool finalKill = false;
        QString remotePath;
        QString localFilePath;
    };

    auto up = std::make_shared<UploadState>();
    up->proc = new QProcess(this);
    up->statProc = new QProcess(this);
    up->watchdog = new QTimer(this);
    up->localSize = fi.size();
    up->remotePath = remotePath;
    up->localFilePath = localFilePath;

    QStringList args = {
        "-C", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=60",
        "-i", SERVER_KEY_PATH, localFilePath,
        QString(SERVER_USER_HOST) + ":" + remotePath
    };
    fprintf(stderr, "[GUI] scp %s\n", qPrintable(args.join(' ')));

    /* Restart the SCP (after removing any partial remote file) */
    std::function<void()> startScp = [this, up, args]() {
        up->lastSize = 0;
        up->lastPct = -1;
        up->watchdog->start();
        up->proc->start("scp", args);
    };

    /* Watchdog: if the remote file stops growing for 45s, kill and retry */
    connect(up->watchdog, &QTimer::timeout, this, [this, up, startScp]() {
        if (up->proc->state() != QProcess::Running) return;
        if (up->retries >= 3) {
            up->finalKill = true;
            fprintf(stderr, "[GUI] Upload FAILED after 3 retries (stalled): %s\n", qPrintable(up->remotePath));
            emitLog("Upload failed after 3 retries (stalled): " + up->remotePath, "error");
            emit uploadFailed(QFileInfo(up->localFilePath).fileName(), "stalled 3 times");
            up->proc->kill();
            return;
        }
        up->retries++;
        up->retrying = true;
        fprintf(stderr, "[GUI] Upload stalled for %s — retrying %d/3\n",
                qPrintable(up->remotePath), up->retries);
        emitLog("Upload stalled for " + up->remotePath + " — retry " +
                QString::number(up->retries) + "/3", "warn");
        if (up->proc->state() != QProcess::NotRunning) {
            up->proc->kill();
            up->proc->waitForFinished(2000);
        }

        /*
         * Clear the partial file on the server, then restart -- without
         * blocking the GUI thread for it.
         *
         * This used to be a stack QProcess with waitForFinished(10000), so a
         * stalled upload froze the entire interface for up to ten seconds at
         * exactly the moment the user was watching a progress bar. The retry
         * now hangs off the process's own finished signal.
         */
        QStringList rmArgs = {
            "-i", SERVER_KEY_PATH, "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            SERVER_USER_HOST, "rm -f " + up->remotePath
        };
        auto *rmProc = new QProcess(this);
        /* finished() and errorOccurred() can both arrive; only one restart. */
        auto done = std::make_shared<bool>(false);
        auto restart = [rmProc, startScp, done]() {
            if (*done) return;
            *done = true;
            rmProc->deleteLater();
            startScp();
        };
        connect(rmProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, [restart](int, QProcess::ExitStatus) { restart(); });
        connect(rmProc, &QProcess::errorOccurred, this,
                [restart](QProcess::ProcessError) { restart(); });
        rmProc->start("ssh", rmArgs);
    });

    /* Poll the remote file size every 3s for a real progress % */
    auto *progressTimer = new QTimer(this);
    connect(progressTimer, &QTimer::timeout, this, [this, up]() {
        if (up->proc->state() != QProcess::Running) return;
        if (up->statProc->state() == QProcess::Running) return;
        QStringList sizeArgs = {
            "-i", SERVER_KEY_PATH, "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=5", SERVER_USER_HOST,
            "stat -c %s " + up->remotePath
        };
        up->statProc->start("ssh", sizeArgs);
    });
    connect(up->statProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this, up](int code, QProcess::ExitStatus) {
        if (code == 0 && up->proc->state() == QProcess::Running) {
            qint64 remoteSize = QString::fromUtf8(up->statProc->readAllStandardOutput()).trimmed().toLongLong();
            if (remoteSize > 0 && up->localSize > 0) {
                int pct = (int)(remoteSize * 100 / up->localSize);
                if (pct > 100) pct = 100;
                if (pct != up->lastPct) {
                    up->lastPct = pct;
                    fprintf(stderr, "[GUI] Upload %s: %d%% (%lld / %lld bytes)\n",
                            qPrintable(up->remotePath), pct, (long long)remoteSize,
                            (long long)up->localSize);
                    emit uploadProgress(pct, QFileInfo(up->localFilePath).fileName());
                    emitLog("Upload progress: " + QString::number(pct) + "%", "info");
                }
                if (remoteSize != up->lastSize) {
                    up->lastSize = remoteSize;
                    up->watchdog->start();
                }
            }
        }
    });
    progressTimer->start(3000);

    connect(up->proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this, up, progressTimer, ota](int exitCode, QProcess::ExitStatus) {
        if (up->retrying) { up->retrying = false; return; }
        if (up->finalKill) return;
        progressTimer->stop();
        progressTimer->deleteLater();
        up->watchdog->stop();
        up->watchdog->deleteLater();
        if (exitCode == 0) {
            fprintf(stderr, "[GUI] Upload complete: %s\n", qPrintable(up->remotePath));
            emit uploadProgress(100, QFileInfo(up->localFilePath).fileName());
            if (ota)
                emit fileStaged(up->remotePath, QFileInfo(up->localFilePath).fileName());
            else
                emit genericUploaded(up->remotePath);
            emitLog("Staged " + QFileInfo(up->localFilePath).fileName() + " on server.", "success");
        } else {
            QString err = QString::fromUtf8(up->proc->readAllStandardError()).trimmed();
            fprintf(stderr, "[GUI] Upload FAILED (exit=%d): %s : %s\n", exitCode,
                    qPrintable(up->remotePath), qPrintable(err));
            emitLog("SCP upload failed (exit=" + QString::number(exitCode) + ") " + err, "error");
            emit uploadFailed(QFileInfo(up->localFilePath).fileName(), err);
        }
        if (up->statProc->state() != QProcess::NotRunning) {
            up->statProc->kill();
            up->statProc->waitForFinished(2000);
        }
        up->statProc->deleteLater();
        up->proc->deleteLater();
    });

    /* Same missing-scp case as in uploadAndDeployOta(): without this the
       watchdog would keep "retrying" a process that never starts. */
    connect(up->proc, &QProcess::errorOccurred, this,
            [this, up, progressTimer](QProcess::ProcessError e) {
        if (e != QProcess::FailedToStart) return;
        progressTimer->stop();
        progressTimer->deleteLater();
        up->watchdog->stop();
        up->finalKill = true;
        emitLog("Could not run 'scp' — is OpenSSH installed and on PATH?", "error");
        emit uploadFailed(QFileInfo(up->localFilePath).fileName(), "scp not found");
    });

    up->watchdog->setSingleShot(true);
    up->watchdog->setInterval(45000);
    startScp();
}

void MqttClient::fetchOtaFiles(const QString &guestId, const QStringList &serverPaths)
{
    if (!m_connected) {
        emitLog("Cannot fetch: not connected to broker.", "error");
        return;
    }
    if (guestId.isEmpty()) {
        emitLog("Select a guest before fetching files.", "error");
        return;
    }
    if (serverPaths.isEmpty()) {
        emitLog("No files staged.", "error");
        return;
    }

    QStringList parts;
    for (const QString &p : serverPaths)
        parts << QDir::cleanPath(p);
    QString cmd = "fetch " + guestId + " " + parts.join(' ');
    publishCommand(cmd);
    emitLog("Sent fetch for guest '" + guestId + "': " + parts.join(' '), "info");
}

void MqttClient::applyOtaFiles(const QString &guestId, bool restart)
{
    if (!m_connected) {
        emitLog("Cannot apply: not connected to broker.", "error");
        return;
    }
    if (guestId.isEmpty()) {
        emitLog("Select a guest before applying files.", "error");
        return;
    }

    QString cmd = "apply " + guestId + (restart ? "" : " --no-restart");
    publishCommand(cmd);
    emitLog("Sent apply for guest '" + guestId + "'" +
            (restart ? "" : " (no restart)"), "info");
}

/*
 * Download a file from the server to a local path with SCP,
 * reporting progress by polling the partial local file size.
 */
void MqttClient::pushFilesToGuest(const QString &guestId, const QString &serverPath)
{
    if (!m_connected) {
        emitLog("Cannot push files: not connected to broker.", "error");
        return;
    }
    if (guestId.isEmpty()) {
        emitLog("Select a guest before pushing files.", "error");
        return;
    }
    emitLog("Sent pushfiles for guest '" + guestId + "': " + serverPath, "info");
    publishCommand("pushfiles " + guestId + " " + serverPath);
}

bool MqttClient::removeDirRecursive(const QString &path)
{
    QDir dir(path);
    if (!dir.exists()) return true;
    QFileInfoList entries = dir.entryInfoList(QDir::NoDotAndDotDot | QDir::AllEntries);
    for (const QFileInfo &e : entries) {
        if (e.isDir() && !e.isSymLink()) {
            if (!removeDirRecursive(e.absoluteFilePath())) return false;
        } else if (!QFile::remove(e.absoluteFilePath())) {
            return false;
        }
    }
    return dir.rmdir(path);
}

QString MqttClient::buildPushTar(const QVariantList &entries, const QString &outPath)
{
    if (entries.isEmpty()) {
        emitLog("No files to pack.", "error");
        return "";
    }

    /* Stage dir replicating each file at its guest path (no leading '/') */
    QString staged = QDir::tempPath() + "/ota_push_" + QString::number(QCoreApplication::applicationPid());
    {
        QDir sd;
        if (!sd.mkpath(staged)) {
            emitLog("Failed to create tar staging dir: " + staged, "error");
            return "";
        }
    }

    bool ok = true;
    for (const QVariant &v : entries) {
        QVariantMap m = v.toMap();
        QString local = m.value("local").toString();
        QString dest = m.value("dest").toString();
        if (local.isEmpty() || dest.isEmpty()) { ok = false; break; }
        while (dest.startsWith('/')) dest = dest.mid(1);
        QString target = staged + "/" + dest;

        QFileInfo lf(local);
        if (!lf.exists() || !lf.isFile()) {
            emitLog("Missing local file: " + local, "error");
            ok = false;
            break;
        }
        QDir dir;
        if (!dir.mkpath(QFileInfo(target).absolutePath())) { ok = false; break; }
        if (!QFile::copy(local, target)) {
            emitLog("Failed to stage " + local, "error");
            ok = false;
            break;
        }
    }
    if (!ok) {
        removeDirRecursive(staged);
        return "";
    }

    QProcess tar;
    QStringList args = { "-czf", outPath, "-C", staged, "." };
    tar.start("tar", args);
    if (!tar.waitForFinished(300000)) {   /* 5 min cap for big sets */
        tar.kill();
        tar.waitForFinished(3000);
        removeDirRecursive(staged);
        emitLog("tar timed out building the archive", "error");
        return "";
    }
    removeDirRecursive(staged);
    if (tar.exitCode() != 0) {
        emitLog("tar failed: " + QString::fromUtf8(tar.readAllStandardError()).trimmed(), "error");
        return "";
    }
    QFileInfo of(outPath);
    if (!of.exists() || of.size() == 0) {
        emitLog("Archive was not created: " + outPath, "error");
        return "";
    }
    emitLog("Built archive " + outPath + " (" + QString::number(of.size()) + " bytes)", "success");
    return outPath;
}

/*
 * Rewritten to hold its state in a shared_ptr like the upload paths do.
 *
 * The old version owned ScpState and a QElapsedTimer with raw new/delete and
 * freed them only inside the scp-finished handler -- so any path that did not
 * reach it leaked both, and the "ssh stat" step failing to start (no ssh on
 * PATH) meant its finished() never fired, the scp was never launched, and the
 * caller was left waiting on a download that had not been started.
 */
void MqttClient::downloadFromServer(const QString &remotePath, const QString &localPath)
{
    emitLog("Downloading from server: " + remotePath, "info");

    struct ScpState {
        QProcess *sizeProc = nullptr;
        QProcess *proc = nullptr;
        QTimer *progressTimer = nullptr;
        int lastPct = -1;
        qint64 remoteSize = 0;
        QString localPath;
        QString remotePath;
        QElapsedTimer elapsed;
        QString stderrBuf;
        bool started = false;
    };

    auto dl = std::make_shared<ScpState>();
    dl->sizeProc = new QProcess(this);
    dl->proc = new QProcess(this);
    dl->progressTimer = new QTimer(this);
    dl->localPath = localPath;
    dl->remotePath = remotePath;
    dl->elapsed.start();

    /* Launch the transfer once the size probe has answered, however it
       answered -- an unknown size only costs the progress %, it must not stop
       the download. Guarded so it runs exactly once. */
    auto startDownload = [this, dl]() {
        if (dl->started) return;
        dl->started = true;
        dl->sizeProc->deleteLater();

        QStringList scpArgs = {
            "-C",
            "-i", SERVER_KEY_PATH,
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=30",
            QString(SERVER_USER_HOST) + ":" + dl->remotePath,
            dl->localPath
        };

        connect(dl->proc, &QProcess::readyReadStandardError, this,
                [dl]() { dl->stderrBuf += QString::fromUtf8(dl->proc->readAllStandardError()); });

        if (dl->remoteSize > 0) {
            connect(dl->progressTimer, &QTimer::timeout, this, [this, dl]() {
                qint64 localSize = QFileInfo(dl->localPath).size();
                int pct = (int)(localSize * 100 / qMax(dl->remoteSize, (qint64)1));
                if (pct > 100) pct = 100;
                if (pct != dl->lastPct) {
                    dl->lastPct = pct;
                    emit downloadProgress(pct);
                }
                if (pct >= 100)
                    dl->progressTimer->stop();
            });
            dl->progressTimer->start(500);
        }

        connect(dl->proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, [this, dl](int exitCode, QProcess::ExitStatus) {
            dl->progressTimer->stop();
            dl->progressTimer->deleteLater();
            dl->proc->deleteLater();

            if (exitCode == 0) {
                emit downloadProgress(100);
                emitLog("Downloaded to " + dl->localPath + " (" +
                        QString::number(QFileInfo(dl->localPath).size() / 1024) +
                        " KB in " + QString::number(dl->elapsed.elapsed() / 1000) + "s)",
                        "success");
            } else {
                emitLog("SCP download failed (exit=" + QString::number(exitCode) + ") " +
                        dl->stderrBuf.trimmed(), "error");
            }
        });

        connect(dl->proc, &QProcess::errorOccurred, this,
                [this, dl](QProcess::ProcessError e) {
            if (e != QProcess::FailedToStart) return;
            dl->progressTimer->stop();
            emitLog("Could not run 'scp' — is OpenSSH installed and on PATH?", "error");
        });

        dl->proc->start("scp", scpArgs);
    };

    connect(dl->sizeProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [dl, startDownload](int code, QProcess::ExitStatus) {
        if (code == 0)
            dl->remoteSize = QString::fromUtf8(
                dl->sizeProc->readAllStandardOutput()).trimmed().toLongLong();
        else
            fprintf(stderr, "[GUI] ssh stat failed (exit=%d) — no progress %%\n", code);
        startDownload();
    });

    connect(dl->sizeProc, &QProcess::errorOccurred, this,
            [startDownload](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart)
            startDownload();      /* no size, but still try the transfer */
    });

    QStringList sizeArgs = {
        "-i", SERVER_KEY_PATH,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=10",
        SERVER_USER_HOST, "stat -c %s " + remotePath
    };
    dl->sizeProc->start("ssh", sizeArgs);
}

} // namespace Ota
} // namespace PdM
