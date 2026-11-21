#include "runtime_profile.h"
#include "cloud_hooks.h"
#include "cloud_intercept.h"
#include "stats_hooks.h"
#include "gamesplayed_hook.h"
#include "live_playtime.h"

#include "stats_store.h"
#include "stats_handlers.h"
#include "metadata_sync.h"
#include "rpc_handlers.h"
#include "app_state.h"
#include "local_storage.h"
#include "pending_ops_journal.h"
#include "cloud_storage.h"
#include "cloud_provider.h"
#include "cloud_provider_base.h" // g_uploadInFlightCapBytes
#include "http_server.h"
#include "protobuf.h"
#include "json.h"
#include "log.h"
#include "xdg.h"
#include "sha256_hmac.h"

#include <cstring>
#include <climits>
#include <fstream>
#include <atomic>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>
#include <unistd.h>
#include <chrono>
#include <condition_variable>

// Verified macOS ARM64 transport ABI (Steam build 1792618285).
using BYieldingSend_t     = int(*)(void* pThis, const char* method, void* req, void* resp, int* flags);
using NotificationDirect_t = int(*)(void* pThis, const char* method, void* body, int* flags);
using SyncSend2_t         = int(*)(void* pThis, const char* method, void* buf, unsigned int bufLen, void* resp, int* flags);

static std::atomic<BYieldingSend_t>      g_origBYieldingSend{nullptr};
static std::atomic<NotificationDirect_t> g_origNotificationDirect{nullptr};
static std::atomic<SyncSend2_t>          g_origSyncSend2{nullptr};

static std::atomic<bool> g_initialized{false};
static std::atomic<bool> g_shuttingDown{false};
static std::atomic<int>  g_hookRefCount{0};
static std::atomic<bool> g_statsSyncEnabled{false}; // set false by config before any stats init
static std::atomic<bool> g_providerReady{false};
static std::string g_providerName="local",g_loadedConfigDigest="missing";
static std::mutex g_cloudStatusMutex;
static std::atomic<uint64_t> g_cloudRequests{0},g_cloudFailures{0};
static std::atomic<uint32_t> g_cloudLastApp{0};
static std::atomic<int32_t> g_cloudLastResult{0};

// Tracked (not detached) playtime poller; joined at shutdown to avoid UAF on torn-down statics.
static std::thread g_cloudPollerThread;
static std::mutex g_pollerExitMtx;
static std::condition_variable g_pollerExitCv;
static std::atomic<bool> g_pollerExited{false};

// SeedApps does per-app cloud I/O; run it off the init thread so a fresh install's
// hundreds of legacy-migration pulls don't block Steam's userdata load. Tracked +
// joined like the poller so a wedged curl can't run freed statics at shutdown.
static std::thread g_seedThread;
static std::mutex g_seedExitMtx;
static std::condition_variable g_seedExitCv;
static std::atomic<bool> g_seedExited{false};

struct HookGuard {
    HookGuard() { g_hookRefCount.fetch_add(1, std::memory_order_acquire); }
    ~HookGuard() { g_hookRefCount.fetch_sub(1, std::memory_order_release); }
};

extern "C" void CR_SetCrashContext(const char* hook, const char* method, uint32_t appId);
extern "C" void CR_ClearCrashContext();

class CrashContextScope {
public:
    CrashContextScope(const char* hook, const char* method, uint32_t appId) {
        CR_SetCrashContext(hook, method, appId);
    }

    ~CrashContextScope() {
        CR_ClearCrashContext();
    }
};

// Verified Itanium C++ protobuf vtable layout on macOS ARM64:
//   slot[5]  (+40): Clear()
//   slot[9]  (+72): ByteSizeLong() -> int
//   slot[10] (+80): GetCachedSize() -> int
//
// Standalone functions found by signature scan:
//   SerializeToArray(msg, buffer) -> uint8_t* (end pointer)
//   ParseFromArray(msg, data, len) -> int (success)

using SerializeToArray_t = void*(*)(void* msg, void* buffer);
using ParseFromArray_t   = int(*)(void* msg, const void* data, int len);

static SerializeToArray_t g_serializeToArray = nullptr;
static ParseFromArray_t   g_parseFromArray   = nullptr;

bool CloudHooks::ResolveProtobufHelpers(void* steamclientBase, size_t steamclientSize) {
    auto base=reinterpret_cast<uintptr_t>(steamclientBase);
    if(steamclientSize<RuntimeProfile::serialize(base)+32 || !RuntimeProfile::Check_parse(base) || !RuntimeProfile::Check_serialize(base)) {
        LOG("[macOS] Unsupported Steam protobuf helpers; no hooks installed");return false;
    }
    g_parseFromArray=(ParseFromArray_t)(base+RuntimeProfile::parse(base));
    g_serializeToArray=(SerializeToArray_t)(base+RuntimeProfile::serialize(base));
    return true;
}

static std::vector<uint8_t> SerializeMessage(void* msg) {
    if (!msg || !g_serializeToArray) return {};

    // vtable[9] = ByteSizeLong (+72 on ARM64)
    uintptr_t* vtable = *(uintptr_t**)msg;
    if (!vtable || !vtable[9]) return {};
    using ByteSizeFn = size_t(*)(void*);
    size_t size = ((ByteSizeFn)vtable[9])(msg);
    if (size == 0 || size > 64 * 1024 * 1024) return {};

    std::vector<uint8_t> buf(size);
    g_serializeToArray(msg, buf.data());
    return buf;
}

static bool ParseIntoMessage(void* msg, const uint8_t* data, size_t len) {
    if (!msg || !g_parseFromArray || (!data && len)) return false;
    if (len > (size_t)INT_MAX) return false;
    return g_parseFromArray(msg, data, (int)len) != 0;
}

// Serialize a protobuf body object into a thread-local buffer for the
// GamesPlayed observer (runs on Steam's network thread).
static const uint8_t* SerializeBodyTL(void* bodyObj, size_t* outLen) {
    static thread_local std::vector<uint8_t> tlBuf;
    tlBuf = SerializeMessage(bodyObj);
    if (outLen) *outLen = tlBuf.size();
    return tlBuf.empty() ? nullptr : tlBuf.data();
}

void CloudHooks::InstallGamesPlayedObserver(uintptr_t steamclientBase, size_t steamclientSize) {
    if (!g_serializeToArray) {
        LOG("[GamesPlayed] serializer not resolved -- playtime tracking disabled");
        return;
    }

    // Always install -- runs before config sets the toggles; per-message paths
    // already check the live toggle (matches Windows).
    GamesPlayedHook::SetSerializer(&SerializeBodyTL);
    GamesPlayedHook::Install(steamclientBase, steamclientSize);

    if (LivePlaytime::Resolve(steamclientBase, steamclientSize, g_parseFromArray))
        LivePlaytime::InstallUserCapture();


}

static std::optional<CloudIntercept::RpcResult> DispatchCloudRpcImpl(
    const char* method, uint32_t appId, const std::vector<PB::Field>& reqBody) {
    using namespace CloudIntercept;
    if (strcmp(method, RPC_GET_CHANGELIST) == 0)    return HandleGetChangelist(appId, reqBody);
    if (strcmp(method, RPC_LAUNCH_INTENT) == 0)     return HandleLaunchIntent(appId, reqBody);
    if (strcmp(method, RPC_SUSPEND_SESSION) == 0)   return HandleSuspendSession(appId, reqBody);
    if (strcmp(method, RPC_RESUME_SESSION) == 0)    return HandleResumeSession(appId, reqBody);
    if (strcmp(method, RPC_QUOTA_USAGE) == 0)       return HandleQuotaUsage(appId, reqBody);
    if (strcmp(method, RPC_BEGIN_BATCH) == 0)       return HandleBeginBatch(appId, reqBody);
    if (strcmp(method, RPC_BEGIN_UPLOAD) == 0)      return HandleBeginFileUpload(appId, reqBody);
    if (strcmp(method, RPC_COMMIT_UPLOAD) == 0)     return HandleCommitFileUpload(appId, reqBody);
    if (strcmp(method, RPC_COMPLETE_BATCH) == 0)    return HandleCompleteBatch(appId, reqBody);
    if (strcmp(method, RPC_FILE_DOWNLOAD) == 0)     return HandleFileDownload(appId, reqBody);
    if (strcmp(method, RPC_DELETE_FILE) == 0)       return HandleDeleteFile(appId, reqBody);
    return std::nullopt;
}

static std::optional<CloudIntercept::RpcResult> DispatchCloudRpc(
    const char* method,uint32_t appId,const std::vector<PB::Field>& request) {
    using namespace CloudIntercept;
    bool known=false;
    for(auto name:{RPC_GET_CHANGELIST,RPC_LAUNCH_INTENT,RPC_SUSPEND_SESSION,RPC_RESUME_SESSION,RPC_QUOTA_USAGE,RPC_BEGIN_BATCH,RPC_BEGIN_UPLOAD,RPC_COMMIT_UPLOAD,RPC_COMPLETE_BATCH,RPC_FILE_DOWNLOAD,RPC_DELETE_FILE})
        if(strcmp(method,name)==0){known=true;break;}
    if(!known)return std::nullopt;
    std::string loaded;
    {std::lock_guard<std::mutex> lock(g_cloudStatusMutex);loaded=g_loadedConfigDigest;}
    // Never acknowledge local-only success when the chosen provider failed,
    // or use an old provider after the configuration changed without restart.
    auto result=(!g_providerReady.load()||loaded!=ConfigurationDigest())
        ? std::optional<RpcResult>(RpcResult(PB::Writer{},kEResultFail))
        : DispatchCloudRpcImpl(method,appId,request);
    if(result){g_cloudRequests++;g_cloudLastApp=appId;g_cloudLastResult=result->eresult;if(result->eresult!=kEResultOK)g_cloudFailures++;}
    return result;
}

std::string CloudHooks::StatusJSONFields() {
    std::string provider,digest;
    {std::lock_guard<std::mutex> lock(g_cloudStatusMutex);provider=g_providerName;digest=g_loadedConfigDigest;}
    return ",\"cloudProvider\":\""+provider+"\",\"cloudConfigSHA256\":\""+digest+
        "\",\"cloudReady\":"+(g_initialized.load()&&g_providerReady.load()?"true":"false")+
        ",\"cloudAppsLoaded\":"+std::to_string(CloudIntercept::GetNamespaceApps().size())+
        ",\"cloudRequests\":"+std::to_string(g_cloudRequests.load())+
        ",\"cloudFailures\":"+std::to_string(g_cloudFailures.load())+
        ",\"cloudLastAppID\":"+std::to_string(g_cloudLastApp.load())+
        ",\"cloudLastResult\":"+std::to_string(g_cloudLastResult.load());
}

static std::atomic<bool> g_initFailed{false};

static void EnsureInitialized() {
    if (g_initialized.load(std::memory_order_acquire)) return;
    if (g_initFailed.load(std::memory_order_acquire)) return;

    static std::once_flag s_initFlag;
    std::call_once(s_initFlag, []() {
        // Initialize the intercept layer (parses SLSsteam config, loginusers.vdf)
        CloudIntercept::InitLinux();

        std::string cloudRedirectRoot = XdgConfigHome() + "/CloudRedirect/";
        std::string storageRoot = cloudRedirectRoot + "storage";

        // Initialize CloudStorage with cloud provider from config.json
        std::unique_ptr<ICloudProvider> provider;
        std::string configPath = cloudRedirectRoot + "config.json";
        std::ifstream configFile(configPath);
        if (configFile) {
            std::string configStr((std::istreambuf_iterator<char>(configFile)), {});
            configFile.close();
            auto cfg = Json::Parse(configStr);
            std::string providerName = cfg["provider"].str();
            {
                std::lock_guard<std::mutex> lock(g_cloudStatusMutex);
                g_loadedConfigDigest=crypto::Sha256Hex(configStr);
                g_providerName=(providerName.empty()?"local":providerName);
                if(g_providerName!="local"&&g_providerName!="folder"&&g_providerName!="webdav"&&g_providerName!="s3"&&g_providerName!="r2"&&g_providerName!="gdrive"&&g_providerName!="onedrive")g_providerName="unknown";
            }
            g_providerReady=providerName.empty()||providerName=="local";

            MetadataSync::syncAchievements = cfg["sync_achievements"].boolean();
            MetadataSync::syncPlaytime = cfg["sync_playtime"].boolean();
            g_statsSyncEnabled.store(MetadataSync::syncAchievements || MetadataSync::syncPlaytime);

            if (!providerName.empty() && providerName != "local") {
                provider = CreateCloudProvider(providerName);
                if (provider) {
                    // Resolve the credential path the same way the CLI does:
                    // config.json token_paths[provider] -> legacy token_path ->
                    // convention filename (r2_credentials.json etc). Previously
                    // this hardcoded "tokens_<provider>.json", which silently
                    // failed for R2 (r2_credentials.json) and left the app in
                    // local-only mode with no cloud sync.
                    std::string tokenPath = ResolveProviderTokenPath(
                        cloudRedirectRoot, configStr, providerName);
                    LOG("[macOS] Cloud provider '%s': resolving credentials at %s",
                        providerName.c_str(), tokenPath.c_str());
                    if (provider->Init(tokenPath)) {
                        LOG("[macOS] Cloud provider '%s' initialized (tokens: %s)",
                            provider->Name(), tokenPath.c_str());
                        if (!provider->IsAuthenticated()) {
                            LOG("[macOS] ERROR: %s not authenticated -- managed cloud RPCs will fail until configured and restarted",
                                provider->Name());
                            provider.reset();
                        }
                        else g_providerReady=true;
                    } else {
                        LOG("[macOS] WARNING: Cloud provider '%s' init FAILED (credentials path: %s) -- "
                            "managed cloud RPCs will fail. Check credentials and restart Steam.",
                            providerName.c_str(), tokenPath.c_str());
                        provider.reset();
                    }
                } else {
                    LOG("[macOS] ERROR: Unknown cloud provider '%s', managed cloud RPCs will fail",
                        providerName.c_str());
                }
            }
        } else {
            LOG("[macOS] No config.json at %s -- local-only mode", configPath.c_str());
            g_providerReady=true;
        }

        CloudStorage::Init(cloudRedirectRoot, std::move(provider));
        if(!g_providerReady.load())g_statsSyncEnabled=false;
    
        LocalStorage::Init(storageRoot);
        LocalMetadataStore::Init(storageRoot);
        PendingOpsJournal::Init(storageRoot);
        HttpServer::Start(storageRoot, CloudIntercept::GetAccountId());

        // Stats/achievement/playtime subsystem; skipped entirely when disabled.
        if (g_statsSyncEnabled.load(std::memory_order_relaxed)) {
        // Stats sync as one account-wide blob at <accountId>/0/stats.json (appId ->
        // stats JSON), not one blob per app (a Drive round-trip per app at startup).
        StatsStore::SetCloudProvider(
            // pullAll: one download of the account blob, split into per-app entries.
            [](std::unordered_map<uint32_t, std::string>& out) -> bool {
                uint32_t accountId = CloudIntercept::GetAccountId();
                if (accountId == 0) return false;
                std::vector<uint8_t> data;
                auto fetch = CloudStorage::FetchCloudMetadataStatus(
                    accountId, CloudIntercept::kAccountScopeAppId, "stats.json", data);
                if (fetch == CloudStorage::MetadataFetch::Error)
                    return false; // transient failure -> keep the existing cloud cache
                if (fetch == CloudStorage::MetadataFetch::Missing || data.empty())
                    return true;  // no account blob yet -> empty (not a failure)
                Json::Value root = Json::Parse(
                    std::string(reinterpret_cast<const char*>(data.data()), data.size()));
                if (root.type != Json::Type::Object) return true;
                for (const auto& [appIdStr, appVal] : root.objVal) {
                    uint32_t appId = (uint32_t)strtoul(appIdStr.c_str(), nullptr, 10);
                    if (appId == 0) continue;
                    out[appId] = Json::Stringify(appVal);
                }
                return true;
            },
            // Merge against the exact downloaded version. WebDAV/S3/R2 reject
            // stale writers; a retry re-reads and merges both devices' progress.
            [](uint32_t accountId, const std::unordered_map<uint32_t, std::string>& all) -> bool {
                auto resetApps = StatsStore::ConsumeResetApps();
                bool ok = CloudStorage::MergeCloudMetadataText(accountId,
                    CloudIntercept::kAccountScopeAppId, "stats.json",
                    [&all](const std::string& current, std::string& merged) {
                        Json::Value root = current.empty() ? Json::Object() : Json::Parse(current);
                        if (root.type != Json::Type::Object) return false;
                        for (const auto& [appId, json] : all) {
                            if (!appId) continue;
                            const auto key = std::to_string(appId);
                            auto base = root.has(key) ? Json::Stringify(root.objVal[key]) : std::string();
                            // Durable reset revisions arbitrate even if another
                            // device resets while this write is being retried.
                            auto entry = Json::Parse(StatsStore::MergeAppStatsJson(base, json));
                            if (entry.type != Json::Type::Object) return false;
                            root.objVal[key] = std::move(entry);
                        }
                        merged = Json::Stringify(root);
                        return true;
                    });
                if (!ok) StatsStore::RestoreResetApps(resetApps);
                return ok;
            },
            // pullLegacy: read one app's old per-app blob for migration into the account blob.
            [](uint32_t appId) -> std::string {
                CloudStorage::InflightSyncScope guard;
                if (!guard.entered) return std::string();
                uint32_t accountId = CloudIntercept::GetAccountId();
                if (accountId == 0) return std::string();
                std::vector<uint8_t> data;
                if (CloudStorage::DownloadCloudMetadataWithLegacyFallback(
                        accountId, appId, "stats.json", nullptr, data) && !data.empty())
                    return std::string(reinterpret_cast<const char*>(data.data()), data.size());
                return std::string();
            },
            // pullLegacyPlaytime: read one app's first-format Playtime/<appId>.bin from cloud.
            [](uint32_t appId) -> std::string {
                CloudStorage::InflightSyncScope guard;
                if (!guard.entered) return std::string();
                uint32_t accountId = CloudIntercept::GetAccountId();
                if (accountId == 0) return std::string();
                std::vector<uint8_t> data;
                if (CloudStorage::DownloadLegacyPlaytimeBlob(accountId, appId, data))
                    return std::string(reinterpret_cast<const char*>(data.data()), data.size());
                return std::string();
            });
        // Track playtime/stats for namespace (lua) apps only -- real owned games
        // must never have their playtime recorded or synced.
        StatsHandlers::SetNamespacePredicate(
            [](uint32_t appId) { return CloudIntercept::IsStatsApp(appId); });
        StatsStore::SetNamespacePredicate(
            [](uint32_t appId) { return CloudIntercept::IsStatsApp(appId); });
        StatsStore::SetAccountIdProvider(
            []() -> uint32_t { return CloudIntercept::GetAccountId(); });
        StatsStore::Init(cloudRedirectRoot, CloudIntercept::GetSteamPath());
        StatsHandlers::Init();
        // Seed managed apps on a background thread: SeedApps does a cloud read per
        // app, which on the init thread would block Steam's userdata load. The store
        // is g_mutex-serialized so a launch racing the seed is safe.
        if (MetadataSync::syncAchievements.load(std::memory_order_relaxed) ||
            MetadataSync::syncPlaytime.load(std::memory_order_relaxed)) {
            g_seedThread = std::thread([] {
                if (!g_shuttingDown.load(std::memory_order_acquire))
                    StatsStore::SeedApps(CloudIntercept::GetStatsApps());
                {
                    std::lock_guard<std::mutex> lk(g_seedExitMtx);
                    g_seedExited.store(true, std::memory_order_release);
                }
                g_seedExitCv.notify_all();
            });
        }

        // Re-pull cloud every 60s for cross-device playtime. Tracked thread (joined at shutdown).
        g_cloudPollerThread = std::thread([] {
            for (;;) {
                for (int i = 0; i < 60 && !g_shuttingDown.load(std::memory_order_acquire); ++i)
                    sleep(1);
                if (g_shuttingDown.load(std::memory_order_acquire)) break;
                // Pure playtime feature: skip the cloud pull + live push when off.
                if (!MetadataSync::syncPlaytime.load(std::memory_order_relaxed) && !MetadataSync::syncAchievements.load(std::memory_order_relaxed)) continue;
                auto apps=CloudIntercept::GetStatsApps();
                if(MetadataSync::AchievementsEnabled())for(auto app:apps)StatsStore::CaptureNativeUnlocks(app);
                auto changed = StatsStore::RefreshFromCloud(apps);
                StatsStore::FlushAll();
                if (!changed.empty() && LivePlaytime::Ready()) {
                    PB::Writer body = StatsHandlers::BuildLastPlayedNotificationBody(changed);
                    if (body.Size() > 0)
                        LivePlaytime::Queue(body.Data());
                }
            }
            // LAST action: signal shutdown that a join is now instantaneous.
            {
                std::lock_guard<std::mutex> lk(g_pollerExitMtx);
                g_pollerExited.store(true, std::memory_order_release);
            }
            g_pollerExitCv.notify_all();
        });
        StatsHooks::SetProtobufHelpers(
            [](void* msg) { return SerializeMessage(msg); },
            [](void* msg, const uint8_t* data, size_t len) {
                return ParseIntoMessage(msg, data, len);
            });
        } else {
            LOG("[Stats] Stats sync disabled -- skipping StatsStore/StatsHandlers/poller init");
        }

        g_initialized.store(true, std::memory_order_release);
        std::atexit(&CloudHooks::ShutdownStorage);
        
        LOG("[macOS] Storage initialized: root=%s, accountId=%u, namespaceApps=%zu",
            storageRoot.c_str(), CloudIntercept::GetAccountId(),
            CloudIntercept::GetNamespaceApps().size());

        // Manifest system fetches CN/manifest on-demand; no bulk startup sync.
        if (CloudStorage::IsCloudActive()) {
            LOG("[StartupSync] Cloud active; metadata will be fetched on-demand per app");
        }
    });
}

void CloudHooks::InitializeStorage() { EnsureInitialized(); }
void CloudHooks::ObserveAccount(uint64_t sid) {
    uint32_t account=(uint32_t)sid;
    if(!account||((sid>>52)&15)!=1||account==CloudIntercept::GetAccountId())return;
    CloudIntercept::SetAccountId(account);
    if(g_statsSyncEnabled){StatsStore::ResetForAccountSwitch(account);StatsHandlers::ResetSessions();}
}

void CloudHooks::SetOriginals(void* origSlot5, void* origSlot7, void* origSlot8) {
    g_origBYieldingSend.store(reinterpret_cast<BYieldingSend_t>(origSlot5), std::memory_order_release);
    g_origNotificationDirect.store(reinterpret_cast<NotificationDirect_t>(origSlot7), std::memory_order_release);
    g_origSyncSend2.store(reinterpret_cast<SyncSend2_t>(origSlot8), std::memory_order_release);
}

static bool IsCloudRpc(const char* methodName) {
    return methodName && strncmp(methodName, "Cloud.", 6) == 0;
}

// Hook: BYieldingSendMessageAndGetReply (slot 5)
//
// 32-bit cdecl: int(void* this, const char* method, void* req, void* resp, int* flags)
// This is the primary synchronous RPC path.

extern "C" int hook_BYieldingSend(void* pThis, const char* methodName, void* request, void* response, int* flags)
{
    HookGuard guard;
    if (g_shuttingDown.load(std::memory_order_acquire)) {
        auto fn = g_origBYieldingSend.load(std::memory_order_acquire);
        return fn ? fn(pThis, methodName, request, response, flags) : 0;
    }
    CrashContextScope crashContext("BYieldingSend:entry", methodName, 0);
    auto origFn = g_origBYieldingSend.load(std::memory_order_acquire);
    
    // Spin-wait for originals (installed before hooks in correct order).
    for (int i = 0; !origFn && i < 1000; ++i) {
        usleep(100);
        origFn = g_origBYieldingSend.load(std::memory_order_acquire);
    }
    if (!origFn) return 0;

    // Drain queued stats work on the network thread (no-op when stats disabled).
    if (g_statsSyncEnabled.load(std::memory_order_relaxed)) {
        LivePlaytime::DrainOnNetThread();
    }

    // Native stats / playtime service methods (Player.*) ride this same path.
    // Skipped entirely when stats sync is disabled -- no init, no interception.
    if (g_statsSyncEnabled.load(std::memory_order_relaxed) &&
        methodName && g_serializeToArray && g_parseFromArray) {
        if (strcmp(methodName, StatsHandlers::RPC_GET_USER_STATS) == 0) {
            EnsureInitialized();
            if (StatsHooks::TryHandleGetUserStats(methodName, request, response, flags))
                return 1;
            return origFn(pThis, methodName, request, response, flags);
        }
        if (strcmp(methodName, StatsHandlers::RPC_GET_LAST_PLAYED) == 0) {
            EnsureInitialized();
            int result = origFn(pThis, methodName, request, response, flags);
            if (result)
                StatsHooks::MergeLastPlayedTimes(methodName, request, response);
            return result;
        }
    }

    if (!CloudIntercept::HasNamespaceApps() || !IsCloudRpc(methodName) || !g_serializeToArray || !g_parseFromArray)
        return origFn(pThis, methodName, request, response, flags);

    // Extract raw protobuf bytes
    auto reqBytes = SerializeMessage(request);
    if (reqBytes.empty()) {
        return origFn(pThis, methodName, request, response, flags);
    }

    auto reqFields = PB::Parse(reqBytes.data(), reqBytes.size());
    uint32_t appId = CloudRpcUtils::ExtractAppId(methodName, reqFields);
    if (appId == 0) {
        return origFn(pThis, methodName, request, response, flags);
    }
    CR_SetCrashContext("BYieldingSend:app", methodName, appId);

    if (!CloudIntercept::IsNamespaceApp(appId)) {
        return origFn(pThis, methodName, request, response, flags);
    }
    EnsureInitialized();
    CR_SetCrashContext("BYieldingSend:namespace", methodName, appId);

    // FileDownload: call original first (yields), then patch response with our URL.
    if (strcmp(methodName, CloudIntercept::RPC_FILE_DOWNLOAD) == 0) {
        LOG("[Hook] FileDownload app=%u: calling original first", appId);
        int origResult = origFn(pThis, methodName, request, response, flags);
        LOG("[Hook] FileDownload app=%u: original returned %d, patching", appId, origResult);

        auto dispatched = DispatchCloudRpc(methodName, appId, reqFields);
        if (!dispatched.has_value()) {
            return origResult;
        }
        auto& result = *dispatched;

        if (response && result.body.Size() > 0) {
            if (!ParseIntoMessage(response, result.body.Data().data(), result.body.Size())) {
                LOG("[Hook] FileDownload: ParseFromArray failed, keeping original");
                return origResult;
            }
        }
        if (flags) {
            flags[2] = 1;
            flags[3] = result.eresult;
        }
        LOG("[Hook] FileDownload app=%u: patched (eresult=%d, %zu bytes)",
            appId, result.eresult, result.body.Size());
        return 1;
    }

    uint32_t accountId = CloudIntercept::GetAccountId();
    if (accountId == 0) {
        return origFn(pThis, methodName, request, response, flags);
    }

    LocalStorage::InitApp(accountId, appId);
    CR_SetCrashContext("BYieldingSend:metadata-init", methodName, appId);
    LocalMetadataStore::InitApp(accountId, appId);

    CR_SetCrashContext("BYieldingSend:dispatch", methodName, appId);
    auto dispatched = DispatchCloudRpc(methodName, appId, reqFields);
    if (!dispatched.has_value()) {
        return origFn(pThis, methodName, request, response, flags);
    }
    auto& result = *dispatched;

    LOG("[Hook] INTERCEPT BYieldingSend %s app=%u -> %zu bytes, eresult=%d",
        methodName, appId, result.body.Size(), result.eresult);

#ifdef DEBUG_HEX_DUMP
    {
        auto& d = result.body.Data();
        std::string hex;
        for (size_t i = 0; i < d.size() && i < 64; i++) {
            char tmp[4]; snprintf(tmp, sizeof(tmp), "%02X ", d[i]);
            hex += tmp;
        }
        LOG("[Hook]   response hex: %s", hex.c_str());
    }
#endif

    // Parse response bytes into the response protobuf object
    if (response && result.body.Size() > 0) {
        CR_SetCrashContext("BYieldingSend:parse-response", methodName, appId);
        if (!ParseIntoMessage(response, result.body.Data().data(), result.body.Size())) {
            LOG("[Hook] BYieldingSend %s: ParseFromArray failed for response! Falling through.",
                methodName);
            return origFn(pThis, methodName, request, response, flags);
        }
        LOG("[Hook]   ParseFromArray succeeded");
    }

    // Flags layout: [0]=routing, [1]=mode, [2]=transport_success, [3]=eresult
    if (flags) {
        flags[2] = 1;  // transport success
        flags[3] = result.eresult;
    }

    LOG("[Hook]   returning success for %s app=%u", methodName, appId);
    return 1;  // success
}

// Hook: NotificationDirect (slot 7)
//
// Suppress cloud notifications for namespace apps.

static uint32_t CheckNotificationNamespaceApp(const char* methodName, void* body) {
    if (!body || !g_serializeToArray) return 0;

    auto bodyBytes = SerializeMessage(body);
    if (bodyBytes.empty()) {
        LOG("[Hook-Notif] %s: body serialization empty", methodName);
        return 0;
    }

    auto fields = PB::Parse(bodyBytes.data(), bodyBytes.size());
    // For Cloud notifications, appId is field 1
    auto* appField = PB::FindField(fields, 1);
    if (!appField) {
        LOG("[Hook-Notif] %s: no field 1 (appId) in body", methodName);
        return 0;
    }

    uint32_t appId = (uint32_t)appField->varintVal;
    if (CloudIntercept::IsNamespaceApp(appId)) {
        return appId;
    }
    return 0;
}

extern "C" int hook_NotificationDirect(void* pThis, const char* methodName, void* body, int* flags)
{
    HookGuard guard;
    if (g_shuttingDown.load(std::memory_order_acquire)) {
        auto fn = g_origNotificationDirect.load(std::memory_order_acquire);
        return fn ? fn(pThis, methodName, body, flags) : 0;
    }
    CrashContextScope crashContext("NotificationDirect:entry", methodName, 0);
    auto origFn = g_origNotificationDirect.load(std::memory_order_acquire);
    for (int i = 0; !origFn && i < 1000; ++i) {
        usleep(100);
        origFn = g_origNotificationDirect.load(std::memory_order_acquire);
    }
    if (!origFn) return 0;

    // Only intercept Cloud.* notifications
    if (!IsCloudRpc(methodName)) {
        return origFn(pThis, methodName, body, flags);
    }

    uint32_t appId = CheckNotificationNamespaceApp(methodName, body);
    CR_SetCrashContext("NotificationDirect:checked", methodName, appId);
    if (appId == 0) {
        // Not a namespace app - pass through to Steam servers
        LOG("[Hook-Notif] %s: not namespace, passing through", methodName);
        return origFn(pThis, methodName, body, flags);
    }

    // ExitSyncDone: let Steam process it (updates remotecache.vdf CN).
    if (strcmp(methodName, CloudIntercept::RPC_EXIT_SYNC) == 0) {
        CR_SetCrashContext("NotificationDirect:exit-sync", methodName, appId);
        auto bodyBytes = SerializeMessage(body);
        auto fields = PB::Parse(bodyBytes.data(), bodyBytes.size());
        uint64_t clientId = 0;
        bool uploadsCompleted = false;
        bool uploadsRequired = false;
        if (auto* f = PB::FindField(fields, 2)) clientId = f->varintVal;
        if (auto* f = PB::FindField(fields, 3)) uploadsCompleted = f->varintVal != 0;
        if (auto* f = PB::FindField(fields, 4)) uploadsRequired = f->varintVal != 0;
        uint32_t accountId = CloudIntercept::GetAccountId();
        if (accountId != 0) {
            PendingOpsJournal::RecordExitSyncState(accountId, appId,
                uploadsCompleted, uploadsRequired, clientId);
            // Native-faithful: ExitSyncDone is fire-and-forget (notification, no
            // response). Dispatch session release off Steam's thread.
            std::thread([accountId, appId, clientId] {
                CloudStorage::InflightSyncScope guard;
                if (!guard.entered) return;  // shutting down, skip session release
                CloudStorage::ReleaseCloudSession(accountId, appId, clientId);
            }).detach();
        }
        LOG("[Hook-Notif] %s app=%u: letting Steam process internally", methodName, appId);
        return origFn(pThis, methodName, body, flags);
    }

    // ConflictResolution: parse chose_local_files so HandleLaunchIntent
    // knows whether to skip pre-restore (user chose "keep local files").
    if (strcmp(methodName, CloudIntercept::RPC_CONFLICT) == 0) {
        auto bodyBytes = SerializeMessage(body);
        auto fields = PB::Parse(bodyBytes.data(), bodyBytes.size());
        bool choseLocal = false;
        if (auto* f = PB::FindField(fields, 2)) choseLocal = f->varintVal != 0;
        CloudIntercept::RecordConflictResolution(appId, choseLocal);
    }

    // Suppress other Cloud notifications for namespace apps
    LOG("[Hook-Notif] SUPPRESSED %s app=%u (notification not sent to server)", methodName, appId);
    return 1;
}

// Hook: SyncSend2 (slot 8)
//
// 32-bit cdecl: int(void* this, const char* method, void* buf, uint32_t bufLen, void* resp, int* flags)
// Buffer-based variant -- raw protobuf bytes are directly available.

extern "C" int hook_SyncSend2(void* pThis, const char* methodName, void* buf, unsigned int bufLen, void* response, int* flags)
{
    HookGuard guard;
    if (g_shuttingDown.load(std::memory_order_acquire)) {
        auto fn = g_origSyncSend2.load(std::memory_order_acquire);
        return fn ? fn(pThis, methodName, buf, bufLen, response, flags) : 0;
    }
    CrashContextScope crashContext("SyncSend2:entry", methodName, 0);
    auto origFn = g_origSyncSend2.load(std::memory_order_acquire);
    for (int i = 0; !origFn && i < 1000; ++i) {
        usleep(100);
        origFn = g_origSyncSend2.load(std::memory_order_acquire);
    }
    if (!origFn) return 0;
    
    if (!IsCloudRpc(methodName))
        return origFn(pThis, methodName, buf, bufLen, response, flags);

    if (!buf || bufLen == 0)
        return origFn(pThis, methodName, buf, bufLen, response, flags);

    auto reqFields = PB::Parse(static_cast<const uint8_t*>(buf), bufLen);
    uint32_t appId = CloudRpcUtils::ExtractAppId(methodName, reqFields);

    if (appId == 0) {
        return origFn(pThis, methodName, buf, bufLen, response, flags);
    }
    CR_SetCrashContext("SyncSend2:app", methodName, appId);

    if (!CloudIntercept::IsNamespaceApp(appId)) {
        return origFn(pThis, methodName, buf, bufLen, response, flags);
    }
    EnsureInitialized();
    CR_SetCrashContext("SyncSend2:namespace", methodName, appId);

    uint32_t accountId = CloudIntercept::GetAccountId();
    if (accountId == 0) {
        return origFn(pThis, methodName, buf, bufLen, response, flags);
    }

    LocalStorage::InitApp(accountId, appId);
    CR_SetCrashContext("SyncSend2:metadata-init", methodName, appId);
    LocalMetadataStore::InitApp(accountId, appId);

    CR_SetCrashContext("SyncSend2:dispatch", methodName, appId);
    auto dispatched = DispatchCloudRpc(methodName, appId, reqFields);
    if (!dispatched.has_value()) {
        return origFn(pThis, methodName, buf, bufLen, response, flags);
    }
    auto& result = *dispatched;

    LOG("[Hook] INTERCEPT SyncSend2 %s app=%u -> %zu bytes, eresult=%d",
        methodName, appId, result.body.Size(), result.eresult);

    if (response && result.body.Size() > 0 && g_parseFromArray) {
        CR_SetCrashContext("SyncSend2:parse-response", methodName, appId);
        if (!ParseIntoMessage(response, result.body.Data().data(), result.body.Size())) {
            LOG("[Hook] SyncSend2 %s: ParseFromArray failed", methodName);
            return origFn(pThis, methodName, buf, bufLen, response, flags);
        }
    }

    // Flags layout (from IDA): [0]=routing, [1]=mode, [2]=transport_success, [3]=eresult
    if (flags) {
        flags[2] = 1;  // transport success
        flags[3] = result.eresult;
    }

    return 1;
}

// Hook: IsCloudEnabledForApp (CUserRemoteStorage vtable slot 24)
// 32-bit cdecl: bool(void* this, unsigned int appId)
// Returns true for namespace apps so cloud toggle stays enabled.

using IsCloudEnabledForApp_t = bool(*)(void* pThis, unsigned int appId);
static std::atomic<IsCloudEnabledForApp_t> g_origIsCloudEnabledForApp{nullptr};

void CloudHooks::SetOriginalIsCloudEnabled(void* orig) {
    g_origIsCloudEnabledForApp.store(reinterpret_cast<IsCloudEnabledForApp_t>(orig), std::memory_order_release);
}

extern "C" bool hook_IsCloudEnabledForApp(void* pThis, unsigned int appId)
{
    HookGuard guard;
    if (g_shuttingDown.load(std::memory_order_acquire)) {
        auto fn = g_origIsCloudEnabledForApp.load(std::memory_order_acquire);
        return fn ? fn(pThis, appId) : true;
    }
    CrashContextScope crashContext("IsCloudEnabledForApp:entry", "IsCloudEnabledForApp", appId);
    if (CloudIntercept::IsNamespaceApp(appId)) {
        LOG("[Hook] IsCloudEnabledForApp(%u) -> true (namespace app)", appId);
        return true;
    }

    auto origFn = g_origIsCloudEnabledForApp.load(std::memory_order_acquire);
    if (origFn) {
        return origFn(pThis, appId);
    }
    return true;
}

void CloudHooks::BeginShutdown() {
    g_shuttingDown.store(true, std::memory_order_release);
    GamesPlayedHook::Remove();
    // Shutdown may run on the main thread; discard queued UI work rather than call CUser off-thread.
    LivePlaytime::RemoveUserCapture();
    for (int i = 0; i < 300 && g_hookRefCount.load(std::memory_order_acquire) > 0; ++i)
        usleep(10000); // 10ms, up to 3s total

    // Join the poller before statics are destroyed. Wait bounded on its exit
    // signal: join() if it reached its end (instant), else detach if wedged in
    // curl rather than hang Steam's shutdown. See g_cloudPollerThread.
    if (g_cloudPollerThread.joinable()) {
        {
            std::unique_lock<std::mutex> lk(g_pollerExitMtx);
            g_pollerExitCv.wait_for(lk, std::chrono::seconds(5),
                [] { return g_pollerExited.load(std::memory_order_acquire); });
        }
        if (g_pollerExited.load(std::memory_order_acquire)) {
            g_cloudPollerThread.join();
        } else {
            LOG("[CloudHooks] poller wedged in network call -- detaching");
            g_cloudPollerThread.detach();
        }
    }

    // Same bounded-join discipline for the background seed thread.
    if (g_seedThread.joinable()) {
        {
            std::unique_lock<std::mutex> lk(g_seedExitMtx);
            g_seedExitCv.wait_for(lk, std::chrono::seconds(5),
                [] { return g_seedExited.load(std::memory_order_acquire); });
        }
        if (g_seedExited.load(std::memory_order_acquire)) {
            g_seedThread.join();
        } else {
            LOG("[CloudHooks] seed wedged in network call -- detaching");
            g_seedThread.detach();
        }
    }
}

void CloudHooks::ShutdownStorage() {
    if(!g_initialized.exchange(false))return;
    BeginShutdown();
    if(g_statsSyncEnabled){StatsHandlers::Shutdown();StatsStore::DrainCloudWrites();}
    HttpServer::Stop();
    CloudIntercept::ShutdownRpcHandlers();
    CloudStorage::Shutdown();
}
