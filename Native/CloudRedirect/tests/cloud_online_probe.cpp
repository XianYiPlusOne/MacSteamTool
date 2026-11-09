// Full save protocol in a disposable process. No Steam dylib, IPC or real saves.
#include "cloud_hooks.h"
#include "cloud_intercept.h"
#include "cloud_storage.h"
#include "app_state.h"
#include "rpc_handlers.h"
#include "http_server.h"
#include "json.h"
#include "file_util.h"
#include "local_disk_provider.h"
#include "stats_store.h"
#include <ctime>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <filesystem>
#include <fstream>
#include <cstdio>
#include <cstdlib>

static constexpr uint32_t account = 12345, app = 900003;
static void require(bool ok, const char* message) { if (!ok) { fprintf(stderr, "FAIL: %s\n", message); fflush(nullptr); _Exit(1); } }
static std::vector<PB::Field> fields(const PB::Writer& value) { return PB::Parse(value.Data().data(), value.Size()); }
static void statistics(const std::string& mode, const std::string& root) {
    constexpr uint32_t statsApp = 900004;
    require(StatsStore::WaitForSeed(30000), "statistics startup seeded");
    StatsStore::DrainCloudWrites();
    auto value = StatsStore::Snapshot(statsApp);
    if (mode == "stats-a" || mode == "stats-b" || mode == "stats-concurrent-a" || mode == "stats-concurrent-b" || mode == "stats-offline") {
        const bool a = mode == "stats-a" || mode == "stats-concurrent-a", offline = mode == "stats-offline";
        const uint32_t bit = offline ? 2 : a ? 0 : 1;
        if (value.achievements.empty()) value.achievements.push_back({});
        auto& block = value.achievements[0]; block.statId = 3;
        block.bits |= 1u << bit; block.unlockTimes[bit] = (uint32_t)time(nullptr);
        value.stats = {{3, block.bits, StatsStore::StatMerge::BitwiseOr}, {4, offline ? 30u : a ? 10u : 20u, StatsStore::StatMerge::Overwrite}};
        auto& device = value.playtime.perDevice[offline ? "fixture-c" : a ? "fixture-a" : "fixture-b"];
        if (a) device.windows = 3; else if (offline) device.lin = 7; else device.mac = 5;
        value.playtime.lastPlayedTime = (uint32_t)time(nullptr);
        // Synthetic contributions exercise real serialization/merge, without
        // reporting fake sessions to a Steam client or waiting fake minutes.
        StatsStore::SaveAppStats(statsApp, value);
        StatsStore::FlushAll(); StatsStore::DrainCloudWrites();
    } else if (mode == "stats-reset") {
        StatsStore::ResetStats(statsApp);
        StatsStore::FlushAll(); StatsStore::DrainCloudWrites();
    } else if (mode == "stats-retry") {
        // No new gameplay. A restarted client must retry durable local progress.
        StatsStore::FlushAll(); StatsStore::DrainCloudWrites();
    } else {
        const uint32_t expected = mode == "stats-verify-retry" ? 7 : mode == "stats-verify-reset" ? 0 : 3;
        uint32_t bits = 0; for (const auto& block : value.achievements) bits |= block.bits;
        require(bits == expected, "independent client receives expected merged achievement bits");
        const bool afterRecovery = mode != "stats-verify" && mode != "stats-verify-concurrent";
        require(value.playtime.playtimeWindows == 3 && value.playtime.playtimeMac == 5 &&
                value.playtime.playtimeLinux == (afterRecovery ? 7u : 0u), "per-device platform minutes merge without double counting");
        require(value.playtime.minutesForever == (afterRecovery ? 15u : 8u), "derived total equals independent device contributions");
        if (expected) {
            auto stat = std::find_if(value.stats.begin(), value.stats.end(), [](const auto& s) { return s.statId == 4; });
            require(stat != value.stats.end() && (mode == "stats-verify-concurrent" ? (stat->value == 10 || stat->value == 20) : stat->value == (afterRecovery ? 30u : 10u)), "pending overwrite-stat survives stale cloud refresh");
        }
    }
    CloudHooks::BeginShutdown(); CloudHooks::ShutdownStorage();
    const auto pending = root + "/CloudRedirect/stats/12345/900004.json.pending";
    if (mode == "stats-offline") require(std::filesystem::is_regular_file(pending), "failed upload remains durably pending");
    if (mode == "stats-retry") require(!std::filesystem::exists(pending), "acknowledged payload clears its own retry marker");
    printf("PASS: %s isolated online account statistics; synthetic progress only.\n", mode.c_str());
}
static std::string http(const std::string& method, const std::string& path, const std::string& body = "") {
    int fd = socket(AF_INET, SOCK_STREAM, 0); require(fd >= 0, "socket");
    int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    timeval timeout{15, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    sockaddr_in addr{}; addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); addr.sin_port = htons(HttpServer::GetPort());
    require(connect(fd, (sockaddr*)&addr, sizeof(addr)) == 0, "connect to isolated upload server");
    std::string request = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: " + std::to_string(body.size()) + "\r\nConnection: close\r\n\r\n" + body;
    require(send(fd, request.data(), request.size(), 0) == (ssize_t)request.size(), "send fixture request");
    std::string response; char buffer[4096]; ssize_t count;
    while ((count = recv(fd, buffer, sizeof(buffer), 0)) > 0) response.append(buffer, count);
    close(fd); return response;
}
int main(int argc, char** argv) {
    require(argc == 5, "usage: online-probe provider fixture-credentials new-client-root upload|download");
    const std::string provider = argv[1], credentials = argv[2], root = argv[3], mode = argv[4];
    require(provider == "webdav" || provider == "s3" || provider == "r2" || provider == "folder", "isolated supported providers only");
    const bool stats = mode == "stats-a" || mode == "stats-b" || mode == "stats-concurrent-a" || mode == "stats-concurrent-b" || mode == "stats-offline" || mode == "stats-reset" || mode == "stats-retry" || mode == "stats-verify" || mode == "stats-verify-retry" || mode == "stats-verify-reset" || mode == "stats-verify-concurrent";
    require(stats || mode == "upload" || mode == "download" || mode == "reject-corrupt", "known mode");
    const bool retry = mode == "stats-retry";
    require(root.starts_with("/") && (retry ? std::filesystem::is_regular_file(root + "/.stats-offline-fixture") : !std::filesystem::exists(root)), "client root is new or an explicit offline fixture");
    require(std::filesystem::exists(std::filesystem::path(credentials).parent_path() / ".fluent-cloud-online-fixture"), "explicit disposable credential marker");
    std::filesystem::create_directories(root + "/CloudRedirect");
    std::filesystem::create_directories(root + "/Steam/config");
    setenv("FLUENT_CLOUD_ROOT", root.c_str(), 1);
    setenv("FLUENT_CLOUD_STEAM", (root + "/Steam").c_str(), 1);
    setenv("MACSTEAM_CONFIG", (root + "/unused-macsteam.yaml").c_str(), 1);
    auto config = Json::Parse("{\"enabled\":true,\"apps\":[900003],\"stats_sync_enabled\":false}");
    if (stats) config = Json::Parse("{\"enabled\":true,\"apps\":[900003],\"stats_sync_enabled\":true,\"stats_apps\":[900004],\"sync_achievements\":true,\"sync_playtime\":true}");
    if (mode == "stats-offline") std::ofstream(root + "/.stats-offline-fixture") << "disposable";
    config.objVal["provider"] = Json::String(provider);
    config.objVal["token_paths"] = Json::Object();
    config.objVal["token_paths"].objVal[provider] = Json::String(credentials);
    std::ofstream(root + "/CloudRedirect/config.json") << Json::Stringify(config);
    std::ofstream(root + "/Steam/config/loginusers.vdf") << "\"users\"\n{\n\"76561197960278073\"\n{\n\"MostRecent\" \"1\"\n}\n}\n";
    CloudHooks::InitializeStorage();
    require(CloudStorage::IsCloudActive() && CloudIntercept::GetAccountId() == account, "fixture provider active and account scoped");
    if (stats) { statistics(mode, root); return 0; }
    const std::string filename = "fixture/slot.bin", payload("binary\0save\xff", 12);
    const auto sha = FileUtil::SHA1(reinterpret_cast<const uint8_t*>(payload.data()), payload.size());
    if (mode == "upload") {
        PB::Writer request; request.WriteVarint(1, app); request.WriteString(3, filename);
        auto batch = CloudIntercept::HandleBeginBatch(app, fields(request));
        const auto batchFields = fields(batch.body); const auto batchID = PB::FindField(batchFields, 1);
        require(batch.eresult == 1 && batchID && batchID->varintVal, "begin online batch");
        PB::Writer upload; upload.WriteVarint(1, app); upload.WriteVarint(2, payload.size()); upload.WriteVarint(3, payload.size());
        upload.WriteBytes(4, sha.data(), sha.size()); upload.WriteVarint(5, 1700000000); upload.WriteString(6, filename);
        require(CloudIntercept::HandleBeginFileUpload(app, fields(upload)).eresult == 1, "begin online file");
        require(http("PUT", "/upload/12345/900003/" + filename, payload).starts_with("HTTP/1.1 200"), "stage binary fixture");
        PB::Writer commit; commit.WriteVarint(1, 1); commit.WriteVarint(2, app); commit.WriteString(4, filename);
        auto committed = CloudIntercept::HandleCommitFileUpload(app, fields(commit)); const auto commitFields = fields(committed.body);
        require(PB::FindField(commitFields, 1) && PB::FindField(commitFields, 1)->varintVal == 1, "commit durable online upload");
        PB::Writer complete; complete.WriteVarint(1, app); complete.WriteVarint(2, batchID->varintVal); complete.WriteVarint(3, 1);
        require(CloudIntercept::HandleCompleteBatch(app, fields(complete)).eresult == 1, "complete online batch");
        CloudStorage::WaitForPendingPublish(account, app);
    }
    auto state = CloudStorage::FetchCloudStateForServe(account, app);
    require(state.status == CloudStorage::StateFetchStatus::Ok && state.state.files.count(filename) && state.state.files.at(filename).sha == sha, "remote manifest contains expected file hash");
    if (mode == "reject-corrupt") {
        require(!CloudStorage::SyncFromCloud(account, app), "corrupt remote blob fails synchronization");
        require(!std::filesystem::exists(root + "/CloudRedirect/storage/12345/900003/" + filename), "corrupt save was not promoted");
        CloudHooks::BeginShutdown(); CloudHooks::ShutdownStorage();
        puts("PASS: corrupt remote blob rejected without creating a local save"); return 0;
    }
    if (mode == "download") {
        require(CloudStorage::SyncFromCloud(account, app), "clean client synchronizes manifest and blobs");
        const auto cache = root + "/CloudRedirect/storage/12345/900003/" + filename;
        require(std::filesystem::is_regular_file(cache), "CAS key restored as an actual file, not a directory");
        std::ifstream file(cache, std::ios::binary);
        std::string cached((std::istreambuf_iterator<char>(file)), {});
        require(cached == payload, "fresh client persisted the exact save bytes");
    }
    PB::Writer download; download.WriteVarint(1, app); download.WriteString(2, filename);
    auto descriptor = CloudIntercept::HandleFileDownload(app, fields(download));
    const auto parsed = fields(descriptor.body);
    const std::string path(PB::GetString(parsed, 8));
    require(descriptor.eresult == 1 && path == "/download/12345/900003/" + filename, "download RPC descriptor");
    const auto response = http("GET", path);
    const auto split = response.find("\r\n\r\n");
    require(response.starts_with("HTTP/1.1 200") && split != std::string::npos && response.substr(split + 4) == payload, "downloaded save bytes match exactly");
    CloudHooks::BeginShutdown(); CloudHooks::ShutdownStorage();
    // Exercise the idle wait/notify shutdown race repeatedly, including Init's
    // restart path. All of these queues are empty and use a fixture provider.
    LocalDiskProvider idle; require(idle.Init(root + "/idle-queue"), "idle provider");
    for (int i = 0; i < 50; ++i) {
        CloudWorkQueue::Init(&idle);
        if (i % 2 == 0) CloudWorkQueue::Init(&idle);
        CloudWorkQueue::Shutdown();
    }
    printf("PASS: %s %s full isolated save protocol and remote manifest, binary SHA matches; no Steam IPC or real saves.\n", provider.c_str(), mode.c_str());
}
