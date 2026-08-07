#ifndef OTA_GUI_MQTTCLIENT_H
#define OTA_GUI_MQTTCLIENT_H

#include <QObject>
#include <QString>
#include <QTimer>
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

private:
    bool m_connected = false;
    QString m_statusText;

#ifdef HAVE_MQTT
    MQTTClient m_client = nullptr;
#endif
    QTimer *m_cmdTimer;
    QTimer *m_yieldTimer;
    QTimer *m_reconnectTimer;
    int m_reconnectAttempts = 0;
    QString m_pendingCmd;
    int m_timeoutSec = 15;
};

#endif
