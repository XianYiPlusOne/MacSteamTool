#include "manifest_provider.h"
#include "runtime_settings.h"
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <sys/stat.h>
#include <cstring>
#include <cstdio>
#include <cstdlib>
using Request=uint32_t(*)(void*,uint32_t,uint32_t,uint64_t,const char*,uint64_t*);
struct Definition {const char* name;const char* signature;void* handler;void** original;int optional;int kind;};
void check(bool b,const char* msg){if(!b){fprintf(stderr,"FAIL: %s\n",msg);exit(1);}}
unsigned calls=0;uint32_t steam(void*,uint32_t,uint32_t,uint64_t,const char*,uint64_t* c){++calls;if(c)*c=37;return 42;}
int main(int argc,char** argv){
    check(argc==5,"usage: probe steamclient macsteam fixture-root loopback-url");
    check(ManifestProvider::ParseCode("{\"content\":\"18446744073709551615\"}")==UINT64_MAX,"quoted UInt64 JSON");
    for(auto invalid:{"{\"content\":123}junk","{\"nested\":{\"content\":123}}","{\"content\":true}","{\"content\":1.5}","{\"content\":\"-1\"}","{\"content\":\"1\\u00002\"}"})
        check(ManifestProvider::ParseCode(invalid)==0,"malformed, nested, boolean, fractional or negative JSON rejected");
    std::string root=argv[3],url=argv[4];check(std::filesystem::exists(root+"/.fluent-fixture"),"private fixture");
    setenv("FLUENT_CLOUD_ROOT",root.c_str(),1);
    check(dlopen(argv[1],RTLD_NOW|RTLD_LOCAL),"real Steam library");auto mac=dlopen(argv[2],RTLD_NOW|RTLD_LOCAL);check(mac,"real macSteam library");
    auto defs=(Definition*(*)())dlsym(mac,"sx_hooks_manifest_defs");check(defs,"real manifest accessor");auto d=defs();auto old=*d->original;*d->original=(void*)&steam;
    auto current=(void**)dlsym(mac,"sx_config_current");check(current,"macSteam config");auto oldConfig=*current;*current=nullptr;
    auto configure=[&](const char* mode,const std::string& endpoint){
        auto file=root+"/CloudRedirect/runtime.json";std::ofstream f(file);f<<"{\"manifestProvider\":{\"mode\":\""<<mode<<"\",\"apps\":[\"480\"],\"url\":\""<<endpoint<<"\"}}";f.close();chmod(file.c_str(),0600);RuntimeSettings::Reload();
    };
    check(ManifestProvider::Install(),"real macSteam handler detour");auto fn=(Request)d->handler;uint64_t code=0;
    configure("custom",url+"/valid/{manifest}");check(fn(nullptr,480,481,UINT64_MAX,"public",&code)==1&&code==UINT64_MAX,"exact UInt64 request code");
    check(fn(nullptr,480,481,UINT64_MAX,"public",&code)==1&&calls==0,"cached request bypasses Steam");
    configure("custom",url+"/json/{manifest}");check(fn(nullptr,480,481,123,"public",&code)==1&&code==UINT64_MAX,"JSON integer preserves UInt64 precision");
    check(fn(nullptr,481,481,123,"public",&code)==42&&code==37,"unselected app passthrough");
    check(fn(nullptr,480,481,123,"beta",&code)==42,"beta branch stays native");
    check(fn(nullptr,480,481,123,"public",nullptr)==42,"null output passthrough");
    for(auto mode:{"invalid","overflow","failure","redirect","large"}){configure("custom",url+"/"+mode+"/{manifest}");check(fn(nullptr,480,481,123,"public",&code)==42&&code==37,"invalid provider response falls back");}
    configure("steam",url+"/valid/{manifest}");check(fn(nullptr,480,481,123,"public",&code)==42,"hot switch to native Steam");
    configure("macsteam",url+"/valid/{manifest}");check(fn(nullptr,480,481,123,"public",&code)==42,"hot switch to macSteam");
    check(!ManifestProvider::ValidTemplate("http://evil.invalid/{manifest}")&&!ManifestProvider::ValidTemplate("https://host/{other}/{manifest}")&&!ManifestProvider::ValidTemplate("https://u:p@host/{manifest}"),"template validation");
    check(ManifestProvider::Served()==3&&ManifestProvider::Fallbacks()==5,"provider status counters");
    ManifestProvider::Remove();check(!ManifestProvider::Installed()&&fn(nullptr,480,481,123,"public",&code)==42,"handler restored after remove");
    *d->original=old;*current=oldConfig;
    puts("PASS: actual macSteam 0.8.2 handler, custom/Steam/default hot switch, exact UInt64, cache, app and beta scope, invalid/overflow/HTTP/redirect/size fallback, uninstall.");
}
