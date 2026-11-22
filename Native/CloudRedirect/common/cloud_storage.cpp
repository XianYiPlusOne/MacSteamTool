// Provider metadata used by the statistics store. Game save files are handled by Steam.
#include "cloud_storage.h"
#include "stats_journal.h"
#include "local_disk_provider.h"
#include "google_drive_provider.h"
#include "onedrive_provider.h"
#include "s3_provider.h"
#include "r2_provider.h"
#include "webdav_provider.h"
#include "cloud_metadata_paths.h"
#include "log.h"
#include "json.h"
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <unordered_set>

namespace CloudStorage {

static std::unique_ptr<ICloudProvider>   g_provider;      // may be nullptr (local-only mode)
static std::mutex                        g_mutex;

// Cache confirmed-missing metadata paths to avoid repeated API round trips.
static std::mutex                        g_missingMetadataMutex;
static std::unordered_set<std::string>   g_missingMetadataPaths;

static std::atomic<int>  g_inflightSyncCount{0};
static std::atomic<bool> g_shuttingDown{false};

InflightSyncScope::InflightSyncScope() {
    g_inflightSyncCount.fetch_add(1, std::memory_order_seq_cst);
    if (g_shuttingDown.load(std::memory_order_seq_cst)) {
        g_inflightSyncCount.fetch_sub(1, std::memory_order_seq_cst);
        return;
    }
    entered = true;
}
InflightSyncScope::~InflightSyncScope() {
    if (entered) g_inflightSyncCount.fetch_sub(1, std::memory_order_seq_cst);
}

std::string CloudMetadataPath(uint32_t accountId, uint32_t appId,
                                      const std::string& name) {
    return std::to_string(accountId) + "/" + std::to_string(appId) + "/" + name;
}

static bool IsKnownMissingMetadataPath(const std::string& path) {
    std::lock_guard<std::mutex> lock(g_missingMetadataMutex);
    return g_missingMetadataPaths.count(path) != 0;
}

static void MarkMissingMetadataPath(const std::string& path) {
    std::lock_guard<std::mutex> lock(g_missingMetadataMutex);
    g_missingMetadataPaths.insert(path);
}

static void ClearMissingMetadataPath(const std::string& path) {
    std::lock_guard<std::mutex> lock(g_missingMetadataMutex);
    g_missingMetadataPaths.erase(path);
}

bool UploadCloudMetadataText(uint32_t accountId, uint32_t appId,
                                     const char* name,
                                     const std::string& content) {
    if (!g_provider || !g_provider->IsAuthenticated()) return false;
    std::string path = CloudMetadataPath(accountId, appId, name);
    const uint8_t emptyByte = 0;
    const uint8_t* data = content.empty()
        ? &emptyByte
        : reinterpret_cast<const uint8_t*>(content.data());
    bool uploaded = g_provider->Upload(path, data, content.size());
    if (uploaded) ClearMissingMetadataPath(path);
    return uploaded;
}

bool MergeCloudMetadataText(uint32_t accountId, uint32_t appId, const char* name,
        const std::function<bool(const std::string&, std::string&)>& merge) {
    InflightSyncScope guard;
    if (!guard || !accountId || !g_provider || !g_provider->IsAuthenticated()) return false;
    const auto path = CloudMetadataPath(accountId, appId, name);
    if(appId==0&&std::string_view(name)=="stats.json"&&g_provider->UsesImmutableStats()) {
        const bool ok=StatsJournal::Publish(*g_provider,path,merge);
        if(ok)ClearMissingMetadataPath(path);
        return ok;
    }
    const bool conditional = g_provider->SupportsConditionalWrites();
    for (int attempt = 0; attempt < 6; ++attempt) {
        std::vector<uint8_t> data;
        std::string version;
        if (conditional) {
            if (g_provider->ReadVersioned(path, data, version) == ICloudProvider::ExistsStatus::Error)
                return false; // No strong validator: retain pending data, never blind-overwrite.
        } else if (FetchCloudMetadataStatus(accountId, appId, name, data) == MetadataFetch::Error) return false;
        if (data.size() > 16 * 1024 * 1024) return false;
        const std::string current(data.begin(), data.end());
        std::string merged;
        if (!merge(current, merged) || merged.size() > 16 * 1024 * 1024) return false;
        if (merged == current) return true;
        if (!conditional) return UploadCloudMetadataText(accountId, appId, name, merged);
        const auto result = g_provider->WriteConditional(path, merged, version);
        if (result == ICloudProvider::ConditionalResult::Written) {
            ClearMissingMetadataPath(path);
            return true;
        }
        if (result != ICloudProvider::ConditionalResult::Conflict) return false;
        LOG("[CloudStorage] Metadata changed during upload; re-reading before retry %d", attempt + 1);
        std::this_thread::sleep_for(std::chrono::milliseconds(25 * (attempt + 1)));
    }
    LOG("[CloudStorage] Metadata remained busy; pending upload retained");
    return false;
}

MetadataFetch FetchCloudMetadataStatus(uint32_t accountId, uint32_t appId,
                                       const char* canonicalName,
                                       std::vector<uint8_t>& outData) {
    outData.clear();
    if (!g_provider || !g_provider->IsAuthenticated()) return MetadataFetch::Error;

    if(appId==0&&std::string_view(canonicalName)=="stats.json"&&g_provider->UsesImmutableStats()) {
        StatsJournal::Snapshot snapshot;
        if(!StatsJournal::Read(*g_provider,CloudMetadataPath(accountId,appId,canonicalName),snapshot))return MetadataFetch::Error;
        outData.assign(snapshot.merged.begin(),snapshot.merged.end());
        return snapshot.exists?MetadataFetch::Ok:MetadataFetch::Missing;
    }

    std::string canonicalPath = CloudMetadataPath(accountId, appId, canonicalName);

    if (IsKnownMissingMetadataPath(canonicalPath))
        return MetadataFetch::Missing;

    if (g_provider->Download(canonicalPath, outData)) {
        ClearMissingMetadataPath(canonicalPath);
        return MetadataFetch::Ok;
    }

    auto status = g_provider->CheckExists(canonicalPath);
    if (status == ICloudProvider::ExistsStatus::Missing) {
        MarkMissingMetadataPath(canonicalPath);
        return MetadataFetch::Missing;
    }
    return MetadataFetch::Error;
}

bool DownloadLegacyStats(uint32_t accountId, uint32_t appId, std::vector<uint8_t>& data) {
    return g_provider && g_provider->IsAuthenticated() &&
        g_provider->Download(CloudMetadataPath(accountId, appId, "stats.json"), data);
}

bool DownloadLegacyPlaytimeBlob(uint32_t accountId, uint32_t appId, std::vector<uint8_t>& data) {
    const auto path = CloudMetadataPath(accountId, 0, "blobs/" + CloudIntercept::AccountPlaytimeFilename(appId));
    return g_provider && g_provider->IsAuthenticated() && g_provider->Download(path, data) && !data.empty();
}

// Statistics use provider metadata directly. Startup must leave legacy save caches alone.
void InitStatistics(std::unique_ptr<ICloudProvider> provider) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_shuttingDown.store(false, std::memory_order_seq_cst);
    g_provider = std::move(provider);
}

void Shutdown() {
    LOG("[CloudStorage] Shutting down...");
    g_shuttingDown.store(true, std::memory_order_seq_cst);
    {
        std::lock_guard<std::mutex> missingLock(g_missingMetadataMutex);
        g_missingMetadataPaths.clear();
    }

    // Drain in-flight ops before g_provider teardown (no internal cancel). 5s cap so session switches don't lag.
    {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (g_inflightSyncCount.load(std::memory_order_seq_cst) > 0
               && std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
        }
        int residualSync = g_inflightSyncCount.load(std::memory_order_seq_cst);
        if (residualSync > 0) {
            LOG("[CloudStorage] Shutdown: %d in-flight SyncFromCloud call(s) did not "
                "drain within 5s; leaking provider to avoid UAF", residualSync);
            (void)g_provider.release();
            g_provider = nullptr;
            return;
        }
    }

    if (g_provider) {
        g_provider->Shutdown();
        g_provider.reset();
    }

    LOG("[CloudStorage] Shutdown complete");
}

bool IsCloudActive() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_provider && g_provider->IsAuthenticated();
}

} // namespace CloudStorage

// Factory implementation (declared in cloud_provider.h)
std::unique_ptr<ICloudProvider> CreateCloudProvider(const std::string& name) {
    // case-insensitive compare
    std::string lower = name;
    for (auto& c : lower) c = (char)tolower((unsigned char)c);

    if (lower == "local" || lower == "folder") {
        return std::make_unique<LocalDiskProvider>();
    }
    // R2 and generic S3 use static access-key credentials with per-request
    // SigV4 signing, not OAuth token refresh, so they need no auth-failure
    // callback. R2 is the Cloudflare-specialized subclass of S3Provider.
    if (lower == "r2") {
        return std::make_unique<R2Provider>();
    }
    if (lower == "s3") {
        return std::make_unique<S3Provider>();
    }
    // WebDAV 用配置文件里的 URL + 账号密码直连，不涉及 OAuth 刷新回调。
    if (lower == "webdav" || lower == "dav") {
        return std::make_unique<WebDavProvider>();
    }
    if (lower == "gdrive") {
        return std::make_unique<GoogleDriveProvider>();
    }
    if (lower == "onedrive") {
        return std::make_unique<OneDriveProvider>();
    }
    LOG("[CloudStorage] CreateCloudProvider: unknown provider '%s'", name.c_str());
    return nullptr;
}

std::string ResolveProviderTokenPath(const std::string& configDir,
                                     const std::string& configJson,
                                     const std::string& provider) {
    // Provider 名按大小写不敏感处理：CLI/宿主可能传 "WebDAV"，
    // 而配置文件里的 provider 与 token_paths 键统一写小写。
    std::string p = provider;
    for (auto& c : p) c = (char)tolower((unsigned char)c);

    if (!configJson.empty()) {
        Json::Value root = Json::Parse(configJson);
        if (root.type == Json::Type::Object) {
            // 1) Per-provider registry (survives provider switches).
            const Json::Value& paths = root["token_paths"];
            if (root.has("token_paths") && paths.type == Json::Type::Object) {
                for (const std::string& key : {provider, p}) {
                    if (paths.has(key) && paths[key].type == Json::Type::String &&
                        !paths[key].str().empty())
                        return paths[key].str();
                }
            }
            // 2) Active provider's token_path (legacy / single-provider path).
            std::string active = root["provider"].str();
            for (auto& c : active) c = (char)tolower((unsigned char)c);
            if (root.has("provider") && active == p &&
                root.has("token_path") && root["token_path"].type == Json::Type::String &&
                !root["token_path"].str().empty()) {
                return root["token_path"].str();
            }
        }
    }

    if (p == "local") return configDir + "storage";
    if (p == "folder") return {}; // User must choose an explicit folder.

    // 3) Convention-based fallback. Must match the exact default filenames the
    //    UI writes so a first run works before Settings has persisted an
    //    explicit token_paths entry. Windows and Linux use different names.
    if (p == "r2")       return configDir + "r2_credentials.json";
    if (p == "s3")       return configDir + "s3_credentials.json";
    if (p == "webdav" || p == "dav")
        return configDir + "webdav_credentials.json";
#ifdef _WIN32
    if (p == "gdrive")   return configDir + "google_tokens.json";
    if (p == "onedrive") return configDir + "onedrive_tokens.json";
#endif
    return configDir + "tokens_" + p + ".json";
}
