#include "manifest_provider.h"
#include "runtime_settings.h"
#include "log.h"
#include <curl/curl.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cstring>
#include <mutex>
#include <unordered_map>
extern "C" int DobbyHook(void*,void*,void**);
extern "C" int DobbyDestroy(void*);
namespace ManifestProvider {
std::string JSONCode(const std::string&);
namespace {
using Request=uint32_t(*)(void*,uint32_t,uint32_t,uint64_t,const char*,uint64_t*);
struct Definition {const char* name;const char* signature;void* handler;void** original;int optional;int kind;};
Request previous=nullptr;void** steamOriginal=nullptr;void* target=nullptr;
std::atomic<bool> active{false};std::atomic<unsigned> served{0},fallbacks{0};
std::once_flag curlInit;
struct Entry {uint64_t code;std::chrono::steady_clock::time_point expires;};
std::mutex cacheMutex;std::unordered_map<std::string,Entry> cache;
void replace(std::string& s,const std::string& key,const std::string& value){size_t pos=0;while((pos=s.find(key,pos))!=std::string::npos){s.replace(pos,key.size(),value);pos+=value.size();}}
size_t append(char* data,size_t size,size_t count,void* out){auto& s=*(std::string*)out;if(size&&count>4096/size)return 0;size_t n=size*count;if(s.size()+n>4096)return 0;s.append(data,n);return n;}
uint64_t fetch(const std::string& url){
    std::call_once(curlInit,[]{curl_global_init(CURL_GLOBAL_DEFAULT);});
    auto c=curl_easy_init();if(!c)return 0;std::string body;
    curl_easy_setopt(c,CURLOPT_URL,url.c_str());curl_easy_setopt(c,CURLOPT_PROTOCOLS,(long)(CURLPROTO_HTTP|CURLPROTO_HTTPS));
    curl_easy_setopt(c,CURLOPT_FOLLOWLOCATION,0L);curl_easy_setopt(c,CURLOPT_NOSIGNAL,1L);
    curl_easy_setopt(c,CURLOPT_CONNECTTIMEOUT_MS,2000L);curl_easy_setopt(c,CURLOPT_TIMEOUT_MS,5000L);
    curl_easy_setopt(c,CURLOPT_SSL_VERIFYPEER,1L);curl_easy_setopt(c,CURLOPT_SSL_VERIFYHOST,2L);
    curl_easy_setopt(c,CURLOPT_USERAGENT,"FluentSteamMac/0.1");curl_easy_setopt(c,CURLOPT_WRITEFUNCTION,append);curl_easy_setopt(c,CURLOPT_WRITEDATA,&body);
    auto result=curl_easy_perform(c);long status=0;curl_easy_getinfo(c,CURLINFO_RESPONSE_CODE,&status);curl_easy_cleanup(c);
    return result==CURLE_OK&&status==200?ParseCode(body):0;
}
uint32_t request(void* self,uint32_t app,uint32_t depot,uint64_t gid,const char* branch,uint64_t* code){
    auto config=RuntimeSettings::Current();auto& p=config->manifest;
    if(p.mode=="macsteam"||!p.apps.count(app)||!code)return previous(self,app,depot,gid,branch,code);
    auto original=steamOriginal?(Request)*steamOriginal:nullptr;
    if(!original)return previous(self,app,depot,gid,branch,code);
    // Branch passwords and branch names are never disclosed to a third-party service.
    if(p.mode=="custom"&&(!branch||!strcmp(branch,"public")||!*branch)){
        std::string url=p.url;replace(url,"{app}",std::to_string(app));replace(url,"{depot}",std::to_string(depot));replace(url,"{manifest}",std::to_string(gid));
        // App/depot are part of the cache identity even when omitted from the URL template.
        auto key=std::to_string(app)+":"+std::to_string(depot)+":"+std::to_string(gid)+":"+url;uint64_t found=0;
        {std::lock_guard lock(cacheMutex);auto i=cache.find(key);if(i!=cache.end()&&i->second.expires>std::chrono::steady_clock::now())found=i->second.code;}
        if(!found){found=fetch(url);if(found){std::lock_guard lock(cacheMutex);if(cache.size()>=256)cache.clear();cache[key]={found,std::chrono::steady_clock::now()+std::chrono::seconds(30)};}}
        if(found){*code=found;++served;return 1;}
        ++fallbacks;
    }
    return original(self,app,depot,gid,branch,code);
}
}
bool ValidTemplate(const std::string& s){
    if(s.size()>2048||s.find("{manifest}")==std::string::npos||s.find_first_of("\r\n\t @\\")!=std::string::npos)return false;
    auto expanded=s;replace(expanded,"{manifest}","1");replace(expanded,"{app}","1");replace(expanded,"{depot}","1");
    if(expanded.find_first_of("{}")!=std::string::npos)return false;
    // Local providers are supported only on loopback. Public providers require TLS.
    if(s.starts_with("https://"))return s.size()>8&&s[8]!='/'&&s[8]!='?';
    return s.starts_with("http://127.0.0.1:")||s.starts_with("http://localhost:")||s.starts_with("http://[::1]:");
}
uint64_t ParseCode(const std::string& value){
    auto first=value.find_first_not_of(" \r\n\t"),last=value.find_last_not_of(" \r\n\t");if(first==std::string::npos)return 0;
    auto s=value.substr(first,last-first+1);
    if(s.starts_with("{"))s=JSONCode(s);
    if(s.empty()||s.size()>20)return 0;
    uint64_t n=0;auto parsed=std::from_chars(s.data(),s.data()+s.size(),n);
    return parsed.ec==std::errc()&&parsed.ptr==s.data()+s.size()?n:0;
}
bool Install(){
    if(active)return true;
    for(unsigned i=0;i<_dyld_image_count();i++){
        auto path=_dyld_get_image_name(i);if(!path||!std::string(path).ends_with("/macsteam.dylib"))continue;
        auto h=dlopen(path,RTLD_NOLOAD|RTLD_NOW);if(!h)continue;
        auto version=(const char*(*)())dlsym(h,"macsteam_version");auto count=(int(*)())dlsym(h,"sx_hooks_manifest_count");auto defs=(Definition*(*)())dlsym(h,"sx_hooks_manifest_defs");
        Definition* d=version&&std::string(version())=="0.8.2"&&count&&count()==1&&defs?defs():nullptr;
        if(d&&d->name&&!strcmp(d->name,"GetManifestRequestCode")&&d->handler&&d->original){target=d->handler;steamOriginal=d->original;}
        dlclose(h);break;
    }
    if(!target||DobbyHook(target,(void*)&request,(void**)&previous)){target=nullptr;steamOriginal=nullptr;return false;}
    active=true;LOG("[ManifestProvider] macSteam 0.8.2 handler wrapped; hot switching ready");return true;
}
void Remove(){if(active.exchange(false)){DobbyDestroy(target);std::lock_guard lock(cacheMutex);cache.clear();}}
bool Installed(){return active;}unsigned Served(){return served;}unsigned Fallbacks(){return fallbacks;}
}
