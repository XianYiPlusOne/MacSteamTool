// SwiftUI adapter for ConnectTool 1.6.0. No window, QML engine or UI process.
#include "application/runtime/application_runtime.h"
#include "platform/system/platform_environment.h"
#include <QCoreApplication>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaProperty>
#include <QSocketNotifier>
#include <QTimer>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

static QJsonArray rows(QAbstractListModel *model) {
    QJsonArray result;
    const auto roles = model->roleNames();
    for (int i = 0; i < model->rowCount(); ++i) {
        QJsonObject row;
        for (auto it = roles.begin(); it != roles.end(); ++it)
            row[QString::fromUtf8(it.value())] = QJsonValue::fromVariant(model->data(model->index(i), it.key()));
        row["row"] = i;
        result.append(row);
    }
    return result;
}
static QJsonObject snapshot(ApplicationRuntime &r) {
    QJsonObject s;
    for (const char *key : {"steamReady", "isHost", "isConnected", "status", "connectionMode", "lobbyId", "lobbyName", "publishLobby", "hostSteamId", "selfSteamId", "joinTarget", "roomName", "localPort", "localBindPort", "tcpClients", "tunLocalIp", "tunDeviceName", "relayPing", "relayPops", "friendsRefreshing", "lobbyRefreshing", "chatReminderEnabled", "appVersion", "latestVersion", "updateAvailable", "checkingUpdate", "updateStatusText", "latestReleasePage", "downloadingUpdate", "downloadProgress", "downloadSavedPath"})
        s[key] = QJsonValue::fromVariant(r.property(key));
    s["friends"] = rows(r.friendsModel()); s["members"] = rows(r.membersModel());
    s["lobbies"] = rows(r.lobbiesModel()); s["messages"] = rows(r.chatModel());
    s["pinned"] = QJsonObject::fromVariantMap(r.chatModel()->pinnedMessage());
    s["tunReady"] = connecttool::platform::hasTunPrivileges();
    return s;
}
int main(int argc, char **argv) {
    // Steam prints diagnostics to stdout. Reserve a descriptor exclusively for IPC.
    const int output = dup(STDOUT_FILENO);
    dup2(STDERR_FILENO, STDOUT_FILENO);
    signal(SIGPIPE, SIG_IGN);
    QCoreApplication app(argc, argv);
    QCoreApplication::setOrganizationName("FluentSteam");
    QCoreApplication::setApplicationName("FluentConnect");
    QFile channel; if (!channel.open(output, QIODevice::WriteOnly, QFile::AutoCloseHandle)) return 2;
    auto sendEvent = [&](const QJsonObject &value) {
        auto bytes = QJsonDocument(value).toJson(QJsonDocument::Compact) + '\n';
        if (channel.write(bytes) != bytes.size() || !channel.flush()) app.quit();
    };
    ApplicationRuntime runtime;
    // Sound/dock reminders belong to the host UI, never this background service.
    runtime.setChatReminderEnabled(false);
    QByteArray lastState;
    auto publish = [&] {
        auto state = snapshot(runtime);
        auto bytes = QJsonDocument(state).toJson(QJsonDocument::Compact);
        if (bytes == lastState) return;
        lastState = bytes;
        sendEvent(QJsonObject{{"type", "state"}, {"state", state}});
    };
    QObject::connect(&runtime, &ApplicationRuntime::adminPrivilegesRequired, &app, [&] {
        sendEvent(QJsonObject{{"type", "error"}, {"message", "请先点击“启用 / 修复虚拟网卡”完成检测，再创建或加入房间 / Enable or repair the virtual network before connecting"}});
    });
    QByteArray pending;
    const int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
    fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
    QSocketNotifier input(STDIN_FILENO, QSocketNotifier::Read);
    QObject::connect(&input, &QSocketNotifier::activated, &app, [&] {
        char buf[8192]; ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
        if (n == 0) { runtime.disconnect(); app.quit(); return; }
        if (n < 0) return;
        pending.append(buf, n);
        if (pending.size() > 65536) { runtime.disconnect(); app.exit(2); return; }
        while (pending.contains('\n')) {
            const int end = pending.indexOf('\n'); const auto line = pending.left(end); pending.remove(0, end + 1);
            QJsonParseError parse; auto document = QJsonDocument::fromJson(line, &parse);
            auto command = document.object(); auto op = command["operation"].toString(); auto id = command["id"];
            auto reject = [&](const QString &message) { sendEvent(QJsonObject{{"type", "error"}, {"id", id}, {"message", message}}); };
            if (parse.error != QJsonParseError::NoError || !document.isObject()) { reject("Invalid command JSON"); continue; }
            if (op == "configure") {
                if (runtime.isHost() || runtime.isConnected()) { reject("请先断开当前房间 / Disconnect first"); continue; }
                int mode = command["mode"].toInt(-1), port = command["port"].toInt(0), bind = command["bindPort"].toInt(0);
                if ((mode != 0 && mode != 1) || port < 1 || port > 65535 || bind < 1 || bind > 65535 || command["roomName"].toString().toUtf8().size() > 128) { reject("模式、端口或房间名无效 / Invalid room settings"); continue; }
                runtime.setConnectionMode(mode); runtime.setLocalPort(port); runtime.setLocalBindPort(bind);
                runtime.setRoomName(command["roomName"].toString()); runtime.setPublishLobby(command["published"].toBool());
                runtime.setJoinTarget(command["target"].toString());
            } else if (op == "host") runtime.startHosting();
            else if (op == "join") runtime.joinHost();
            else if (op == "joinLobby") runtime.joinLobby(command["target"].toString());
            else if (op == "disconnect") runtime.disconnect();
            else if (op == "refreshFriends") runtime.refreshFriends();
            else if (op == "refreshLobbies") runtime.refreshLobbies();
            else if (op == "refreshMembers") runtime.refreshMembers();
            else if (op == "filterFriends") runtime.setFriendFilter(command["text"].toString());
            else if (op == "filterLobbies") { runtime.setLobbyFilter(command["text"].toString()); runtime.setLobbySortMode(command["sort"].toInt()); }
            else if (op == "invite") runtime.inviteFriend(command["target"].toString());
            else if (op == "chat") {
                auto message = command["text"].toString();
                if (message.trimmed().isEmpty() || message.toUtf8().size() > 4000) { reject("消息为空或过长 / Message is empty or too long"); continue; }
                if (!runtime.sendChatMessage(message)) { reject("消息发送失败，请检查连接 / Message failed; check connection"); continue; }
            } else if (op == "pin") {
                // Bind the index to the displayed message; incoming messages may shift rows.
                const int row = command["row"].toInt(-1); const auto entry = runtime.chatModel()->entryAt(row);
                if (!entry || entry->steamId != command["steamId"].toString() || entry->message != command["text"].toString() || entry->timestamp.toString(Qt::ISODateWithMs) != command["timestamp"].toString()) { reject("消息列表已变化，请重试 / Message list changed; retry"); continue; }
                runtime.pinChatMessage(row);
            } else if (op == "clearPin") runtime.clearPinnedChatMessage();
            else if (op == "checkUpdate") runtime.checkForUpdates(command["proxy"].toBool());
            else if (op == "downloadUpdate") {
                const auto path = command["path"].toString();
                if (!path.startsWith('/') || path.contains(QChar('\0'))) { reject("Invalid destination"); continue; }
                runtime.downloadUpdate(command["proxy"].toBool(), path);
            } else if (op == "quit") { runtime.disconnect(); app.quit(); }
            else if (op != "snapshot") { reject("Unknown operation"); continue; }
            sendEvent(QJsonObject{{"type", "ack"}, {"id", id}}); publish();
        }
    });
    QTimer timer; QObject::connect(&timer, &QTimer::timeout, &app, [&] { if (getppid() == 1) { runtime.disconnect(); app.quit(); } else publish(); }); timer.start(500);
    runtime.startServices(); publish();
    return app.exec();
}
