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
    require(mode == "upload" || mode == "download" || mode == "reject-corrupt", "known mode");
    require(root.starts_with("/") && !std::filesystem::exists(root), "client root must be new");
    require(std::filesystem::exists(std::filesystem::path(credentials).parent_path() / ".fluent-cloud-online-fixture"), "explicit disposable credential marker");
    std::filesystem::create_directories(root + "/CloudRedirect");
    std::filesystem::create_directories(root + "/Steam/config");
    setenv("FLUENT_CLOUD_ROOT", root.c_str(), 1);
    setenv("FLUENT_CLOUD_STEAM", (root + "/Steam").c_str(), 1);
    setenv("MACSTEAM_CONFIG", (root + "/unused-macsteam.yaml").c_str(), 1);
    auto config = Json::Parse("{\"enabled\":true,\"apps\":[900003],\"stats_sync_enabled\":false}");
    config.objVal["provider"] = Json::String(provider);
    config.objVal["token_paths"] = Json::Object();
    config.objVal["token_paths"].objVal[provider] = Json::String(credentials);
    std::ofstream(root + "/CloudRedirect/config.json") << Json::Stringify(config);
    std::ofstream(root + "/Steam/config/loginusers.vdf") << "\"users\"\n{\n\"76561197960278073\"\n{\n\"MostRecent\" \"1\"\n}\n}\n";
    CloudHooks::InitializeStorage();
    require(CloudStorage::IsCloudActive() && CloudIntercept::GetAccountId() == account, "fixture provider active and account scoped");
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
