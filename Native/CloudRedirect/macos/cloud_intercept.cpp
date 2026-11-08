// macOS adapter: explicit selection or opt-in macSteam main-game tracking.
#include "cloud_intercept.h"
#include "json.h"
#include "xdg.h"
#include "log.h"
#include "presence_apps.h"
#include "sha256_hmac.h"
#include <fstream>
#include <mutex>
#include <unordered_set>
#include <atomic>
#include <sys/stat.h>
#include <cstring>
#include <unistd.h>
static std::mutex g_mutex;
static std::string g_steamPath;
static std::unordered_set<uint32_t> g_apps, g_statsApps;
static std::unordered_set<uint32_t> g_excludedApps;
static bool g_automaticApps=false;
static std::string g_configDigest="missing";
static std::string g_macSteamConfig;
static void RefreshAutomaticApps() {
    if(!g_automaticApps)return;
    g_apps.clear();
    for(const auto& [id,name]:PresenceApps::Read(g_macSteamConfig))if(!g_excludedApps.count(id))g_apps.insert(id);
}
static std::atomic<uint32_t> g_account{0};
static std::string DetectSteamPath() {
    const char* p=getenv("FLUENT_CLOUD_STEAM");
    return p && p[0]=='/' ? std::string(p)+"/" : XdgHome()+"/Library/Application Support/Steam/";
}
static void Refresh() {
    auto path=XdgConfigHome()+"/CloudRedirect/config.json";
    static time_t last=0; static long nanos=-1;
    struct stat st{}; if(lstat(path.c_str(),&st)!=0||!S_ISREG(st.st_mode)||st.st_uid!=getuid()||st.st_size>1024*1024){g_apps.clear();g_statsApps.clear();g_automaticApps=false;g_configDigest="missing";last=0;nanos=-1;return;}
    if(st.st_mtimespec.tv_sec==last&&st.st_mtimespec.tv_nsec==nanos){RefreshAutomaticApps();return;}
    last=st.st_mtimespec.tv_sec;nanos=st.st_mtimespec.tv_nsec;
    std::ifstream file(path);std::string text((std::istreambuf_iterator<char>(file)),{});
    auto config=Json::Parse(text);g_configDigest=crypto::Sha256Hex(text);g_apps.clear();g_statsApps.clear();g_excludedApps.clear();g_automaticApps=false;
    if(config["sync_achievements"].boolean()||config["sync_playtime"].boolean())
        for(const auto& entry:config["stats_apps"].arrVal){auto id=entry.integer();if(id>0&&id<=UINT32_MAX)g_statsApps.insert((uint32_t)id);}
    if(!config["enabled"].boolean())return;
    g_automaticApps=config["automatic_apps"].boolean();
    g_macSteamConfig=config["macsteam_config"].str();
    if(!g_macSteamConfig.empty()&&(g_macSteamConfig[0]!='/'||g_macSteamConfig.find('\0')!=std::string::npos)){g_automaticApps=false;return;}
    for(const auto& entry:config["excluded_apps"].arrVal){auto id=entry.integer();if(id>0&&id<=UINT32_MAX)g_excludedApps.insert((uint32_t)id);}
    if(g_automaticApps){RefreshAutomaticApps();return;}
    for(const auto& entry:config["apps"].arrVal){ auto id=entry.integer();if(id>0&&id<=UINT32_MAX)g_apps.insert((uint32_t)id); }
}
static uint32_t LoadAccountIdFromLoginUsers() {
    std::string steamPath = DetectSteamPath();
    std::string vdfPath = steamPath + "config/loginusers.vdf";

    std::ifstream f(vdfPath);
    if (!f) {
        LOG("[macOS] Cannot open loginusers.vdf at %s", vdfPath.c_str());
        return 0;
    }

    std::string line;
    uint64_t mostRecentSteamId = 0;
    uint64_t autoLoginSteamId = 0;
    uint64_t newestTimestampSteamId = 0;
    uint64_t newestTimestamp = 0;
    uint64_t currentSteamId = 0;
    bool inUser = false;
    int braceDepth = 0;

    while (std::getline(f, line)) {
        // Trim
        size_t start = line.find_first_not_of(" \t\r\n");
        if (start == std::string::npos) continue;
        std::string trimmed = line.substr(start);

        if (trimmed == "{") {
            braceDepth++;
            continue;
        }
        if (trimmed == "}") {
            braceDepth--;
            if (braceDepth == 1) inUser = false;
            continue;
        }

        // At depth 1, look for SteamID64 keys (quoted numbers)
        if (braceDepth == 1 && trimmed.size() > 2 && trimmed[0] == '"') {
            size_t endQuote = trimmed.find('"', 1);
            if (endQuote != std::string::npos) {
                std::string key = trimmed.substr(1, endQuote - 1);
                // Check if it's a numeric SteamID64
                char* endp = nullptr;
                uint64_t sid = strtoull(key.c_str(), &endp, 10);
                if (endp == key.c_str() + key.size() && sid > 76561197960265728ULL) {
                    currentSteamId = sid;
                    inUser = true;
                }
            }
        }

        // At depth 2, look for selection markers
        if (inUser && braceDepth == 2) {
            if (trimmed.find("\"MostRecent\"") != std::string::npos &&
                trimmed.find("\"1\"") != std::string::npos) {
                mostRecentSteamId = currentSteamId;
            }
            if (trimmed.find("\"AutoLogin\"") != std::string::npos &&
                trimmed.find("\"1\"") != std::string::npos) {
                autoLoginSteamId = currentSteamId;
            }
            static const std::string kTimestamp = "\"Timestamp\"";
            if (trimmed.find(kTimestamp) != std::string::npos) {
                size_t vStart = trimmed.find('"', trimmed.find(kTimestamp) + kTimestamp.size());
                if (vStart != std::string::npos) {
                    size_t vEnd = trimmed.find('"', vStart + 1);
                    if (vEnd != std::string::npos) {
                        std::string tsStr = trimmed.substr(vStart + 1, vEnd - vStart - 1);
                        char* endp = nullptr;
                        uint64_t ts = strtoull(tsStr.c_str(), &endp, 10);
                        if (endp == tsStr.c_str() + tsStr.size() && ts > newestTimestamp) {
                            newestTimestamp = ts;
                            newestTimestampSteamId = currentSteamId;
                        }
                    }
                }
            }
        }
    }

    // Priority: MostRecent > AutoLogin > highest Timestamp
    uint64_t selected = mostRecentSteamId;
    const char* method = "MostRecent";
    if (selected == 0) {
        selected = autoLoginSteamId;
        method = "AutoLogin";
    }
    if (selected == 0) {
        selected = newestTimestampSteamId;
        method = "Timestamp";
    }

    if (selected == 0) {
        LOG("[macOS] No user found in loginusers.vdf (tried MostRecent, AutoLogin, Timestamp)");
        return 0;
    }

    uint32_t accountId = (uint32_t)(selected & 0xFFFFFFFF);
    LOG("[macOS] Bootstrapped accountId=%u from SteamID64=%llu via %s (loginusers.vdf)",
        accountId, (unsigned long long)selected, method);
    return accountId;
}


namespace CloudIntercept {
void InitLinux(){std::lock_guard<std::mutex> lock(g_mutex);g_steamPath=DetectSteamPath();g_account=LoadAccountIdFromLoginUsers();Refresh();}
bool IsNamespaceApp(uint32_t app){std::lock_guard<std::mutex> lock(g_mutex);Refresh();return g_apps.count(app)>0;}
bool IsStatsApp(uint32_t app){std::lock_guard<std::mutex> lock(g_mutex);Refresh();return g_statsApps.count(app)>0;}
std::vector<uint32_t> GetStatsApps(){std::lock_guard<std::mutex> lock(g_mutex);Refresh();return {g_statsApps.begin(),g_statsApps.end()};}
bool HasNamespaceApps(){std::lock_guard<std::mutex> lock(g_mutex);Refresh();return !g_apps.empty();}
std::vector<uint32_t> GetNamespaceApps(){std::lock_guard<std::mutex> lock(g_mutex);Refresh();return {g_apps.begin(),g_apps.end()};}
std::string ConfigurationDigest(){std::lock_guard<std::mutex> lock(g_mutex);Refresh();return g_configDigest;}
void RegisterNamespaceApp(uint32_t app){/* Explicit config only; RPCs cannot opt other games in. */}
std::string GetSteamPath(){std::lock_guard<std::mutex> lock(g_mutex);return g_steamPath.empty()?DetectSteamPath():g_steamPath;}
uint32_t GetAccountId(){return g_account.load();}
void SetAccountId(uint32_t account){g_account=account;}
void SetSteamPath(const std::string& path){std::lock_guard<std::mutex> lock(g_mutex);g_steamPath=path;if(!g_steamPath.empty()&&g_steamPath.back()!='/')g_steamPath+='/';}
void Shutdown(){}
}
