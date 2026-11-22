#include "runtime_profile.h"
#include "cloud_hooks.h"
#include "cloud_intercept.h"
#include "stats_hooks.h"
#include "gamesplayed_hook.h"
#include "live_playtime.h"

#include "stats_store.h"
#include "stats_handlers.h"
#include "metadata_sync.h"
#include "cloud_storage.h"
#include "cloud_provider.h"
#include "steam_kv_injector.h"
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
#include <thread>
#include <vector>
#include <unistd.h>
#include <chrono>
#include <condition_variable>

// Verified macOS ARM64 transport ABI (Steam build 1792618285).
using BYieldingSend_t     = int(*)(void* pThis, const char* method, void* req, void* resp, int* flags);

static std::atomic<BYieldingSend_t>      g_origBYieldingSend{nullptr};

static std::atomic<bool> g_initialized{false};
static std::atomic<bool> g_shuttingDown{false};
static std::atomic<int>  g_hookRefCount{0};
static std::atomic<bool> g_statsSyncEnabled{false}; // set false by config before any stats init
static std::atomic<bool> g_providerReady{false};
static std::string g_loadedConfigDigest="missing";
static std::mutex g_cloudStatusMutex;

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

std::string CloudHooks::StatusJSONFields() {
    std::lock_guard<std::mutex> lock(g_cloudStatusMutex);
    return ",\"cloudConfigSHA256\":\"" + g_loadedConfigDigest +
        "\",\"cloudReady\":" + (g_initialized.load() && g_providerReady.load() ? "true" : "false");
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
            }
            g_providerReady=providerName.empty()||providerName=="local";

            MetadataSync::syncAchievements = cfg["sync_achievements"].boolean();
            MetadataSync::syncPlaytime = cfg["sync_playtime"].boolean();
            g_statsSyncEnabled.store(MetadataSync::syncAchievements || MetadataSync::syncPlaytime);

            if (g_statsSyncEnabled && !providerName.empty() && providerName != "local") {
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
                            LOG("[macOS] ERROR: %s not authenticated -- statistics sync requires authentication",
                                provider->Name());
                            provider.reset();
                        }
                        else g_providerReady=true;
                    } else {
                        LOG("[macOS] WARNING: Cloud provider '%s' init FAILED (credentials path: %s) -- "
                            "Statistics sync is unavailable. Check credentials and restart Steam.",
                            providerName.c_str(), tokenPath.c_str());
                        provider.reset();
                    }
                } else {
                    LOG("[macOS] ERROR: Unknown cloud provider '%s', statistics sync is unavailable",
                        providerName.c_str());
                }
            }
        } else {
            LOG("[macOS] No config.json at %s -- local-only mode", configPath.c_str());
            g_providerReady=true;
        }

        if (!g_providerReady.load()) g_statsSyncEnabled = false;

        // Stats/achievement/playtime subsystem; skipped entirely when disabled.
        if (g_statsSyncEnabled.load(std::memory_order_relaxed)) {
        CloudStorage::InitStatistics(std::move(provider));
        // Stats sync as one account-wide blob at <accountId>/0/stats.json (appId ->
        // stats JSON), not one blob per app (a Drive round-trip per app at startup).
        StatsStore::SetCloudProvider(
            // pullAll: one download of the account blob, split into per-app entries.
            [](std::unordered_map<uint32_t, std::string>& out) -> bool {
                uint32_t accountId = CloudIntercept::GetAccountId();
                if (accountId == 0) return false;
                std::vector<uint8_t> data;
                CloudStorage::InflightSyncScope guard;
                if (!guard) return false;
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
                if (CloudStorage::DownloadLegacyStats(accountId, appId, data) && !data.empty())
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
        
    });
}

void CloudHooks::InitializeStorage() { EnsureInitialized(); }
void CloudHooks::ObserveAccount(uint64_t sid) {
    uint32_t account=(uint32_t)sid;
    if(!account||((sid>>52)&15)!=1||account==CloudIntercept::GetAccountId())return;
    CloudIntercept::SetAccountId(account);
    if(g_statsSyncEnabled){StatsStore::ResetForAccountSwitch(account);StatsHandlers::ResetSessions();}
}

void CloudHooks::SetOriginal(void* origSlot5) {
    g_origBYieldingSend.store(reinterpret_cast<BYieldingSend_t>(origSlot5), std::memory_order_release);
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

    return origFn(pThis, methodName, request, response, flags);
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
    if (g_statsSyncEnabled) CloudStorage::Shutdown();
}
