#ifndef OTA_GUI_MQTTCLIENT_H
#define OTA_GUI_MQTTCLIENT_H

#include <QObject>
#include <QString>
#include <QTimer>
#include <QThread>
#include <functional>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QFile>
#include <QDir>

#ifdef HAVE_MQTT
#include <MQTTClient.h>
#endif

class MqttClient : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool connected READ isConnected NOTIFY connectedChanged)

    /* Whether the BOARD is alive -- which is a different question from
       `connected`, and confusing the two is why switching the RPi off used to
       leave the GUI looking perfectly healthy. `connected` is this app's own
       link to the broker, and the broker is on the internet: it stays up
       whatever happens to the board. hostOnline is driven by HMS's heartbeat
       and by the retained will the broker publishes when the board stops
       talking. */
    Q_PROPERTY(bool hostOnline READ hostOnline NOTIFY hostOnlineChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusTextChanged)
    Q_PROPERTY(QString broker READ broker CONSTANT)
    Q_PROPERTY(QString serverUserHost READ serverUserHost CONSTANT)
    /* The QML file picker hardcoded "/home/gemy/" as its starting directory,
       which is one developer's machine and nobody else's. */
    Q_PROPERTY(QString homePath READ homePath CONSTANT)
    Q_PROPERTY(QString serverUploadDir READ serverUploadDir CONSTANT)

public:
    explicit MqttClient(QObject *parent = nullptr);
    ~MqttClient();

    bool isConnected() const;
    QString statusText() const;
    QString broker() const;
    QString serverUserHost() const;
    QString homePath() const;
    QString serverUploadDir() const;

public slots:
    void connectToBroker();
    void disconnectFromBroker();
    void publishCommand(const QString &cmd);

    Q_INVOKABLE void refreshGuests();
    Q_INVOKABLE void startGuest(const QString &id, const QString &ip);
    Q_INVOKABLE void killGuest(const QString &id);
    Q_INVOKABLE void guestInfo(const QString &id);
    Q_INVOKABLE void execCommand(const QString &id, const QString &command);
    Q_INVOKABLE void guestStats(const QString &id);
    Q_INVOKABLE void guestFiles(const QString &id);
    Q_INVOKABLE void uploadAndDeployOta(const QString &guestId, const QString &localFilePath);
    Q_INVOKABLE void uploadOtaFile(const QString &localFilePath, const QString &serverName);
    Q_INVOKABLE void uploadGenericFile(const QString &localFilePath, const QString &serverName);
    Q_INVOKABLE void fetchOtaFiles(const QString &guestId, const QStringList &serverPaths);
    Q_INVOKABLE void applyOtaFiles(const QString &guestId, bool restart);
    Q_INVOKABLE void downloadFromServer(const QString &remotePath, const QString &localPath);
    Q_INVOKABLE void pushFilesToGuest(const QString &guestId, const QString &serverPath);

    /* Interactive shell. HMS has served shellopen/shellwrite/shellclose and
     * streamed shell_out chunks back since it grew shell.c, but nothing here
     * ever sent those commands or listened for the replies, so the feature was
     * unreachable from the GUI. */
    Q_INVOKABLE void shellOpen(const QString &guestId);
    Q_INVOKABLE void shellWrite(const QString &guestId, const QString &data);
    Q_INVOKABLE void shellClose(const QString &guestId);

    /* Likewise addfile / addguest: implemented in ota.c, never called. */
    Q_INVOKABLE void addFileToGuest(const QString &guestId, const QString &serverPath);
    Q_INVOKABLE void addGuest(const QString &guestId, const QString &ifsServerPath,
                              const QString &confServerPath, const QString &ip);

    Q_INVOKABLE void ping();

    /* Pack files (each at an absolute guest path) into one tar.gz.
     * entries: [ {local: "<laptop path>", dest: "<guest absolute path>"}, ... ]
     * Returns the archive path, or "" on failure. */
    Q_INVOKABLE QString buildPushTar(const QVariantList &entries, const QString &outPath);

private slots:
    void onCmdTimeout();
    void attemptReconnect();

public:
    void scheduleReconnect();
    void onConnectionLost();
    void handleStatusMessage(const QString &payload);

signals:
    void connectedChanged();
    void hostOnlineChanged();

    /* One per beat actually received, so the UI can show a live pulse rather
       than a static dot that looks identical whether the link is healthy or
       frozen. Emitted only for real "host" beats, not for ordinary replies --
       a pulse that fired on every message would flicker at the rate of
       whatever else is going on and stop meaning anything. */
    void heartbeat();
    void statusTextChanged();
    void logMessage(const QString &text, const QString &type);
    void guestListReceived(const QString &json);
    void guestInfoReceived(const QString &json);
    void cmdResult(const QString &cmd, const QString &guest, bool success, const QString &msg);
    void execOutput(const QString &guest, const QString &output);
    void guestStatsReceived(const QString &json);
    void guestFilesReceived(const QString &json);
    void otaProgress(const QString &guest, const QString &stage, int progress, const QString &msg);
    void otaResult(const QString &guest, bool success, const QString &msg);
    void pongReceived();
    void uploadProgress(int percent, const QString &fileName);
    void downloadProgress(int percent);
    void fileStaged(const QString &serverPath, const QString &localName);
    void genericUploaded(const QString &serverPath);
    void uploadFailed(const QString &localName, const QString &err);

    /* Interactive shell stream from HMS. */
    void shellOpened(const QString &guest, const QString &msg);
    void shellOutput(const QString &guest, const QString &data);
    void shellClosed(const QString &guest, const QString &msg);

    void addFileResult(const QString &guest, bool success, const QString &msg);
    void addGuestResult(const QString &guest, bool success, const QString &msg);

private:
    void emitLog(const QString &text, const QString &type);
    void setConnected(bool c);
    void setStatusText(const QString &t);
    void publishOtaCmd(const QString &guestId, const QString &remotePath);
    void publishNoWait(const QString &cmd);
    void startScpUpload(const QString &localFilePath, const QString &remotePath, bool ota);
    void teardownClient();
    static bool removeDirRecursive(const QString &path);

public:
    bool hostOnline() const;

    /*
     * Diagnostic trace: milliseconds since start, thread id, tag, message.
     *
     * Written to ~/ota_gui_diag.log as well as stderr, and flushed on every
     * line -- a hang is exactly the case where a buffered log tells you
     * nothing, because the interesting part never reaches the disk.
     *
     * The thread id is there on purpose. Three threads touch this program's
     * state -- the GUI, Paho's receive thread, and the MQTT worker -- and
     * "which thread was that on" is the question a freeze usually turns on.
     */
    Q_INVOKABLE void diag(const QString &tag, const QString &msg);

private:
    void setHostOnline(bool online);

    bool m_connected = false;

    /* Starts false: until a beat or a retained marker arrives we do not know
       the board is there, and claiming it is would be the very bug this
       exists to fix. */
    bool m_hostOnline = false;
    QTimer *m_hostWatchdog = nullptr;

    QString m_statusText;

#ifdef HAVE_MQTT
    MQTTClient m_client = nullptr;
#endif
    /*
     * Every Paho call happens on this thread and nowhere else.
     *
     * Paho's synchronous MQTTClient API is not built for two threads. Setting
     * callbacks gives the library its own receive thread, and the GUI thread
     * was calling MQTTClient_publish on the same handle at the same time. It
     * survived the small traffic and died on the Monitor: opening the page
     * publishes `stats guest-1` while a reply is being delivered, and the
     * client stopped dead -- not merely the reply, the heartbeats too:
     *
     *     [GUI] >> hms/cmd : stats guest-1
     *     [GUI] >> hms/cmd : stats guest-1
     *     (nothing, ever again)
     *
     * Marshalling every call onto one thread removes the race by
     * construction, and takes the blocking 5s connect off the GUI thread as a
     * side effect.
     */
    QThread *m_mqttThread = nullptr;
    QObject *m_mqttWorker = nullptr;
    void onMqttThread(std::function<void()> fn);

    QTimer *m_cmdTimer;
    QTimer *m_reconnectTimer;
    int m_reconnectAttempts = 0;
    QString m_pendingCmd;
    int m_timeoutSec = 15;
};

#endif
