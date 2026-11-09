#include "runtime_settings.h"
#include "json.h"
#include "xdg.h"
#include "ticket_hooks.h"
#include "ticket_layout.h"
#include "ownership_hooks.h"
#include "onlinefix.h"
#include "manifest_provider.h"
#include "cloud_hooks.h"
#include "access_tokens.h"
#include "presence_apps.h"
#include "presence_shortcuts.h"
#include "cloud_intercept.h"
#include "gamesplayed_hook.h"
#include "live_playtime.h"
#include "metadata_sync.h"
#include <fcntl.h>
#include <fstream>
#include <filesystem>
#include <atomic>
#include <thread>
#include <chrono>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
namespace RuntimeSettings {
namespace {
struct State {std::shared_ptr<const Configuration> value=std::make_shared<const Configuration>();std::thread worker;std::atomic<bool> stop{false};};
State& state(){static auto* s=new State;return *s;}
std::vector<uint8_t> hex(const std::string& s){
    if(s.empty()||s.size()>8192||s.size()%2)return {};
    auto digit=[](char c)->int{if(c>='0'&&c<='9')return c-'0';if(c>='A'&&c<='F')return c-'A'+10;if(c>='a'&&c<='f')return c-'a'+10;return -1;};
    std::vector<uint8_t> out;for(size_t i=0;i<s.size();i+=2){int a=digit(s[i]),b=digit(s[i+1]);if(a<0||b<0)return {};out.push_back((a<<4)|b);}return out;
}
uint32_t appID(const std::string& s){if(s.empty()||s.size()>10||s.find_first_not_of("0123456789")!=std::string::npos)return 0;auto n=strtoull(s.c_str(),nullptr,10);return n<=UINT32_MAX?(uint32_t)n:0;}
}
std::shared_ptr<const Configuration> Current(){return std::atomic_load(&state().value);}
void Reload(){
    Configuration next;auto path=XdgConfigHome()+"/CloudRedirect/runtime.json";struct stat info{};
    // Absence selects the new automatic default. An existing unreadable or
    // invalid file must never silently turn a user's hidden status back on.
    if(lstat(path.c_str(),&info)==0||errno!=ENOENT)next.presence="unchanged";
    // This file contains reusable tickets. Reject symlinks and group/world-readable copies.
    if(lstat(path.c_str(),&info)==0&&S_ISREG(info.st_mode)&&info.st_uid==getuid()&&!(info.st_mode&0077)&&info.st_size<=16*1024*1024){
        std::ifstream f(path);std::string text((std::istreambuf_iterator<char>(f)),{});auto root=Json::Parse(text);
        auto& manifest=root["manifestProvider"];auto mode=manifest["mode"].str();
        if(mode=="steam"||(mode=="custom"&&ManifestProvider::ValidTemplate(manifest["url"].str()))){
            next.manifest.mode=mode;next.manifest.url=manifest["url"].str();
            for(auto& val:manifest["apps"].arrVal){auto id=appID(val.str());if(id&&next.manifest.apps.size()<4096)next.manifest.apps.insert(id);}
        }
        auto p=root["presence"].str();if(p=="automatic"||p=="selected"||p=="none")next.presence=p;
        if(p=="spacewar")next.presence="selected"; // Preserve the saved selection with the current compatibility policy.
        for(auto& [key,val]:root["presenceApps"].objVal){auto id=appID(key);if(id&&val.str().size()<=512)next.presenceApps[id]=val.str();}
        for(auto& [key,val]:root["tickets"].objVal){
            auto id=appID(key);if(!id||!val["enabled"].boolean())continue;
            Ticket t;t.app=id;t.ownership=hex(val["ownership"].str());t.encrypted=hex(val["encrypted"].str());
            if(t.ownership.size()<148||t.encrypted.empty())continue;
            if(!TicketLayout::Locate(t.ownership,id,t.appOffset,t.signature,t.steamID))continue;
            next.tickets[id]=std::move(t);
        }
    }
    next.managedApps=PresenceApps::Read();
    if(next.presence=="automatic")next.presenceApps=next.managedApps;
    else if(next.presence=="selected"){
        auto names=PresenceApps::Read();for(auto& [id,name]:next.presenceApps)if(names.count(id))name=names.at(id);
    }
    next.accessTokens=AccessTokens::Read();
    next.presenceAccount=CloudIntercept::GetAccountId();
    if(next.presence=="automatic"||next.presence=="selected")next.presenceShortcuts=PresenceShortcuts::Read(CloudIntercept::GetSteamPath(),next.presenceAccount);
    std::atomic_store(&state().value,std::make_shared<const Configuration>(std::move(next)));
}
static void WriteStatus(){
    auto path=XdgConfigHome()+"/CloudRedirect/runtime-status.json";auto tmp=path+".tmp";
    std::string text="{\"pid\":"+std::to_string(getpid())+",\"tickets\":"+(TicketHooks::Installed()?"true":"false")+",\"presence\":"+(GamesPlayedHook::Installed()?"true":"false")+",\"playtimeWriter\":"+(LivePlaytime::Ready()?"true":"false")+",\"statistics\":"+(MetadataSync::AchievementsEnabled()?"true":"false")+",\"playtime\":"+(MetadataSync::PlaytimeEnabled()?"true":"false")+",\"ownershipServed\":"+std::to_string(TicketHooks::OwnershipServed())+",\"encryptedServed\":"+std::to_string(TicketHooks::EncryptedServed())+",\"callbacksServed\":"+std::to_string(TicketHooks::CallbacksServed())+",\"gamesObserved\":"+std::to_string(GamesPlayedHook::Observed())+",\"presenceChanged\":"+std::to_string(GamesPlayedHook::Rewritten())+",\"manifestProvider\":"+(ManifestProvider::Installed()?"true":"false")+",\"manifestServed\":"+std::to_string(ManifestProvider::Served())+",\"manifestFallbacks\":"+std::to_string(ManifestProvider::Fallbacks())+",\"accessTokenRequests\":"+std::to_string(GamesPlayedHook::TokenRequests())+",\"accessTokensLoaded\":"+std::to_string(Current()->accessTokens.size())+"}";
    auto current=Current();text.pop_back();
    text+=",\"onlineFix\":"+std::string(OnlineFix::Installed()?"true":"false")+",\"onlineFixAppID\":"+std::to_string(OnlineFix::ActiveApp());
    text+=",\"ownershipFix\":"+std::string(OwnershipHooks::Installed()?"true":"false")+",\"ownershipChecks\":"+std::to_string(OwnershipHooks::Repaired())+",\"ownershipMissingOwner\":"+std::to_string(OwnershipHooks::MissingOwner());
    text+=",\"presenceMode\":\""+current->presence+"\",\"presenceAppsLoaded\":"+std::to_string(current->presenceApps.size())+
        ",\"presenceSent\":"+std::to_string(GamesPlayedHook::Sent())+",\"presenceFailures\":"+std::to_string(GamesPlayedHook::Failed())+
        ",\"presenceLastAppID\":"+std::to_string(GamesPlayedHook::LastApp())+",\"presenceLastSentAt\":"+std::to_string(GamesPlayedHook::LastSentAt())+
        ",\"presenceIdentity\":\"shortcut-or-spacewar\",\"presenceShortcutsLoaded\":"+std::to_string(current->presenceShortcuts.size())+
        ",\"presenceLastGameID\":"+std::to_string(GamesPlayedHook::LastGameID())+CloudHooks::StatusJSONFields()+"}";
    int fd=open(tmp.c_str(),O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW,0600);if(fd<0)return;
    bool ok=write(fd,text.data(),text.size())==(ssize_t)text.size();close(fd);if(ok)rename(tmp.c_str(),path.c_str());else unlink(tmp.c_str());
}
void Start(){Reload();auto& s=state();if(s.worker.joinable())return;s.stop=false;s.worker=std::thread([]{while(!state().stop){std::this_thread::sleep_for(std::chrono::milliseconds(1000));if(!state().stop){Reload();WriteStatus();}}});}
void Stop(){auto& s=state();s.stop=true;if(s.worker.joinable())s.worker.join();std::atomic_store(&s.value,std::make_shared<const Configuration>());}
}
