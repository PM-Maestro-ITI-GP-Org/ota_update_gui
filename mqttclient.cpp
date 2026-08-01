#include "mqttclient.h"
#include <QDateTime>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QStandardPaths>
#include <QCoreApplication>
#include <cstring>
#include <functional>
#include <memory>

#define MQTT_BROKER "tcp://139.185.38.211:1883"
#define MQTT_USER "mqttuser"
#define MQTT_PASS "123456"

#define CMD_TOPIC "hms/cmd"
#define STATUS_TOPIC "hms/status"

#define SERVER_USER_HOST "maxmaster@139.185.38.211"
#define SERVER_UPLOAD_DIR "/home/maxmaster/uploads"
#define SERVER_KEY_PATH (QDir::homePath() + "/.ssh/id_ed25519")

#ifdef HAVE_MQTT

struct MqttContext {
    MqttClient *self;
    QString clientId;
    MQTTClient_connectOptions opts;
};

static void on_connection_lost(void *context, char *cause)
{
    auto *ctx = static_cast<MqttContext *>(context);
    fprintf(stderr, "[MQTT] Connection lost: %s\n", cause ? cause : "unknown");
    QMetaObject::invokeMethod(ctx->self, [self = ctx->self]() {
        if (self->isConnected())
            self->scheduleReconnect();
    }, Qt::QueuedConnection);
}

static int on_message(void *context, char *topicName, int topicLen,
                      MQTTClient_message *message)
{
    auto *ctx = static_cast<MqttContext *>(context);
    int tlen = (topicLen > 0) ? topicLen : (topicName ? strlen(topicName) : 0);
    QString topic = QString::fromUtf8(topicName, tlen);
    QString payload = QString::fromUtf8(
        static_cast<char *>(message->payload), message->payloadlen);

    fprintf(stderr, "[MQTT] << %s : %s\n", qPrintable(topic), payload.left(160).toUtf8().constData());

    QMetaObject::invokeMethod(ctx->self, [self = ctx->self, topic, payload]() {
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
    , m_cmdTimer(new QTimer(this)), m_yieldTimer(new QTimer(this))
{
    m_cmdTimer->setSingleShot(true);
    connect(m_cmdTimer, &QTimer::timeout, this, &MqttClient::onCmdTimeout);
    m_yieldTimer->setInterval(50);
    connect(m_yieldTimer, &QTimer::timeout, this, []() {
#ifdef HAVE_MQTT
        MQTTClient_yield();
#endif
    });
    m_reconnectTimer = new QTimer(this);
    m_reconnectTimer->setSingleShot(true);
    m_reconnectTimer->setInterval(5000);
    connect(m_reconnectTimer, &QTimer::timeout, this, &MqttClient::attemptReconnect);
}

MqttClient::~MqttClient()
{
#ifdef HAVE_MQTT
    if (m_client) {
        MQTTClient_disconnect(m_client, 1000);
        MQTTClient_destroy(&m_client);
    }
#endif
}

bool MqttClient::isConnected() const { return m_connected; }

QString MqttClient::statusText() const { return m_statusText; }

QString MqttClient::broker() const { return MQTT_BROKER; }

QString MqttClient::serverUserHost() const { return SERVER_USER_HOST; }

void MqttClient::setConnected(bool c)
{
    if (m_connected != c) {
        m_connected = c;
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

    auto *ctx = new MqttContext;
    ctx->self = this;
    ctx->clientId = "ota_gui_" + QString::number(QDateTime::currentMSecsSinceEpoch());

    int rc = MQTTClient_create(&m_client, MQTT_BROKER, ctx->clientId.toStdString().c_str(),
                              MQTTCLIENT_PERSISTENCE_NONE, nullptr);
    if (rc != MQTTCLIENT_SUCCESS) {
        fprintf(stderr, "[GUI] MQTTClient_create failed: %d\n", rc);
        emitLog("Failed to create MQTT client.", "error");
        setStatusText("Create failed");
        delete ctx;
        return;
    }

    ctx->opts = MQTTClient_connectOptions_initializer;
    ctx->opts.connectTimeout = 5;
    ctx->opts.username = MQTT_USER;
    ctx->opts.password = MQTT_PASS;

    MQTTClient_setCallbacks(m_client, ctx, on_connection_lost, on_message, nullptr);

    rc = MQTTClient_connect(m_client, &ctx->opts);
    if (rc == MQTTCLIENT_SUCCESS) {
        MQTTClient_subscribe(m_client, STATUS_TOPIC, 0);
        m_reconnectTimer->stop();
        m_reconnectAttempts = 0;
        setConnected(true);
        setStatusText("Connected");
        m_yieldTimer->start();
        fprintf(stderr, "[GUI] Connected to broker at " MQTT_BROKER "\n");
        emitLog("Connected to broker.", "success");
        refreshGuests();
    } else {
        setConnected(false);
        setStatusText("Connection failed");
        fprintf(stderr, "[GUI] MQTT connection failed (error %d)\n", rc);
        emitLog(QString("MQTT connection failed (error %1).").arg(rc), "error");
        MQTTClient_destroy(&m_client);
        m_client = nullptr;
        delete ctx;
        scheduleReconnect();
    }
#else
    setStatusText("Demo mode");
    emitLog("MQTT not available — running in demo mode.", "warning");
#endif
}

void MqttClient::disconnectFromBroker()
{
    m_yieldTimer->stop();
    m_reconnectTimer->stop();
    m_reconnectAttempts = 0;
#ifdef HAVE_MQTT
    if (m_client) {
        MQTTClient_disconnect(m_client, 1000);
        MQTTClient_destroy(&m_client);
        m_client = nullptr;
    }
#endif
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
    m_reconnectAttempts++;
    fprintf(stderr, "[GUI] Reconnect attempt %d scheduled\n", m_reconnectAttempts);
    if (m_reconnectTimer->isActive())
        return;
    m_reconnectTimer->start();
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
    MQTTClient_publish(m_client, CMD_TOPIC, utf8.size(), utf8.constData(), 0, false, nullptr);
    m_pendingCmd = cmd;
    m_cmdTimer->start(m_timeoutSec * 1000);
#else
    (void)cmd;
#endif
}

void MqttClient::onCmdTimeout()
{
    fprintf(stderr, "[GUI] TIMEOUT: no response for '%s'\n", m_pendingCmd.toUtf8().constData());
    emitLog(QString("No response from HMS (timeout %1s) — check that hms is running on the host.").arg(m_timeoutSec), "error");
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
    if (!m_connected || !m_client) {
        emitLog("Cannot send command: not connected.", "error");
        return;
    }
    QByteArray utf8 = cmd.toUtf8();
    fprintf(stderr, "[GUI] >> %s : %s\n", CMD_TOPIC, cmd.toUtf8().constData());
    MQTTClient_publish(m_client, CMD_TOPIC, utf8.size(), utf8.constData(), 0, false, nullptr);
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
    } else if (state == "pong") {
        emit pongReceived();
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
        QProcess *proc;
        QProcess *statProc;
        qint64 localSize;
        int lastPct = -1;
        QString guestId;
        QString remotePath;
        QString localFilePath;
    };

    auto *up = new UploadState;
    up->proc = new QProcess(this);
    up->statProc = new QProcess(this);
    up->localSize = fi.size();
    up->guestId = guestId;
    up->remotePath = remotePath;
    up->localFilePath = localFilePath;

    QStringList args = {
        "-C",
        "-o", "StrictHostKeyChecking=no",
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
            "-o", "StrictHostKeyChecking=no",
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
        }
        if (up->statProc->state() != QProcess::NotRunning) {
            up->statProc->kill();
            up->statProc->waitForFinished(2000);
        }
        up->statProc->deleteLater();
        up->proc->deleteLater();
        delete up;
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
        "-C", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15",
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
        QStringList rmArgs = {
            "-i", SERVER_KEY_PATH, "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
            SERVER_USER_HOST, "rm -f " + up->remotePath
        };
        QProcess rmProc;
        rmProc.start("ssh", rmArgs);
        rmProc.waitForFinished(10000);
        startScp();
    });

    /* Poll the remote file size every 3s for a real progress % */
    auto *progressTimer = new QTimer(this);
    connect(progressTimer, &QTimer::timeout, this, [this, up]() {
        if (up->proc->state() != QProcess::Running) return;
        if (up->statProc->state() == QProcess::Running) return;
        QStringList sizeArgs = {
            "-i", SERVER_KEY_PATH, "-o", "StrictHostKeyChecking=no",
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

void MqttClient::downloadFromServer(const QString &remotePath, const QString &localPath)
{
    emitLog("Downloading from server: " + remotePath, "info");

    auto *st = new QProcess(this);
    st->setParent(this);

    auto *elapsed = new QElapsedTimer();
    elapsed->start();

    QStringList sizeArgs = {
        "-i", SERVER_KEY_PATH,
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=10",
        SERVER_USER_HOST, "stat -c %s " + remotePath
    };

    struct ScpState {
        QProcess *proc;
        QTimer *progressTimer;
        int lastPct = -1;
        qint64 remoteSize = 0;
        QString localPath;
        QString remotePath;
        QElapsedTimer *elapsed;
        QString stderrBuf;
    };

    auto *dl = new ScpState;
    dl->proc = new QProcess(this);
    dl->progressTimer = new QTimer(this);
    dl->localPath = localPath;
    dl->remotePath = remotePath;
    dl->elapsed = elapsed;

    connect(st, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this, st, dl](int code, QProcess::ExitStatus) {
        st->deleteLater();
        if (code == 0) {
            dl->remoteSize = QString::fromUtf8(
                st->readAllStandardOutput()).trimmed().toLongLong();
        } else {
            fprintf(stderr, "[GUI] ssh stat failed (exit=%d)\n", code);
        }

        QStringList scpArgs = {
            "-C",
            "-i", SERVER_KEY_PATH,
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=30",
            dl->remotePath, dl->localPath
        };

        connect(dl->proc, &QProcess::readyReadStandardError, this,
                [dl]() { dl->stderrBuf += QString::fromUtf8(dl->proc->readAllStandardError()); });

        if (dl->remoteSize > 0) {
            connect(dl->progressTimer, &QTimer::timeout, this, [this, dl]() {
                QFile f(dl->localPath);
                qint64 localSize = 0;
                if (f.open(QIODevice::ReadOnly)) {
                    localSize = f.size();
                    f.close();
                }
                int pct = localSize * 100 / qMax(dl->remoteSize, (qint64)1);
                if (pct > 100) pct = 100;
                if (pct != dl->lastPct) {
                    dl->lastPct = pct;
                    emit downloadProgress(pct);
                    emitLog("Download progress: " + QString::number(pct) + "%", "info");
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
            qint64 totalTime = dl->elapsed->elapsed();
            delete dl->elapsed;

            if (exitCode == 0) {
                emit downloadProgress(100);
                emitLog("Downloaded to " + dl->localPath +
                        " (" + QString::number(QFileInfo(dl->localPath).size() / 1024) + " KB in " +
                        QString::number(totalTime / 1000) + "s)", "success");
            } else {
                fprintf(stderr, "%s\n", qPrintable(dl->stderrBuf));
                emitLog("SCP download failed (exit=" + QString::number(exitCode) + ")", "error");
            }
            delete dl;
        });

        dl->proc->start("scp", scpArgs);
    });

    st->start("ssh", sizeArgs);
}
