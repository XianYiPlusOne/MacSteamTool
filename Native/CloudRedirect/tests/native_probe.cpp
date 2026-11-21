#include "runtime_profile.h"
// Integration test against a real Steam dylib in an isolated process and data root.
// Never opens a Steam IPC session or touches the user's Steam directory.
#include "vtable_hook.h"
#include "cloud_hooks.h"
#include "cloud_intercept.h"
#include "local_disk_provider.h"
#include "http_server.h"
#include "autocloud_scan.h"
#include "steam_profile.h"
#include "json.h"
#include "save_inventory.h"
#include "rpc_handlers.h"
#include "cloud_storage.h"
#include "app_state.h"
#include "file_util.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <vector>

extern "C" int FluentCloudInstallHooks();
extern "C" void FluentCloudRemoveHooks();
extern "C" int hook_BYieldingSend(void*,const char*,void*,void*,int*);
static int passthrough(void*,const char*,void*,void*,int*) { return 777; }
static bool cloudOff(void*,unsigned int) { return false; }
extern "C" bool hook_IsCloudEnabledForApp(void*,unsigned int);
static void require(bool condition,const char* message) { if(!condition){fprintf(stderr,"FAIL: %s\n",message);fflush(nullptr);_Exit(1);} }
static std::vector<PB::Field> fields(const PB::Writer& message) { return PB::Parse(message.Data().data(),message.Size()); }
static std::string http(const std::string& method,const std::string& path,const std::string& body="") {
    int fd=socket(AF_INET,SOCK_STREAM,0);require(fd>=0,"HTTP socket");
    int one=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    timeval timeout{5,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    sockaddr_in a{};a.sin_family=AF_INET;a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);a.sin_port=htons(HttpServer::GetPort());
    require(connect(fd,(sockaddr*)&a,sizeof(a))==0,"loopback connect");
    auto req=method+" "+path+" HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: "+std::to_string(body.size())+"\r\nConnection: close\r\n\r\n"+body;
    require(send(fd,req.data(),req.size(),0)==(ssize_t)req.size(),"send HTTP request");
    std::string response;char b[4096];ssize_t n;while((n=recv(fd,b,sizeof(b),0))>0)response.append(b,n);close(fd);return response;
}
int main(int argc,char** argv) {
    require(argc==3||argc==4,"usage: probe steamclient.dylib new-private-test-root [failed-provider]");
    const bool failedProvider=argc==4;
    std::string root=argv[2];
    require(root.starts_with("/")&&!std::filesystem::exists(root),"test root must be new and absolute");
    std::filesystem::create_directories(root+"/CloudRedirect");
    std::filesystem::create_directories(root+"/Steam/config");
    setenv("FLUENT_CLOUD_ROOT",root.c_str(),1);setenv("FLUENT_CLOUD_STEAM",(root+"/Steam").c_str(),1);
    setenv("MACSTEAM_CONFIG",(root+"/macsteam.yaml").c_str(),1);
    const std::string initialApps="Apps:\n  - 480 # Fixture\n  - 481 # DLC @480\n  - 484 # Excluded\n";
    std::ofstream(root+"/macsteam.yaml")<<initialApps;
    const std::string config="{\"enabled\":true,\"automatic_apps\":true,\"excluded_apps\":[484],\"provider\":\""+std::string(failedProvider?"unknown":"folder")+"\",\"token_paths\":{\"folder\":\""+root+"/redirected\"},\"stats_sync_enabled\":false}";
    std::ofstream(root+"/CloudRedirect/config.json")<<config;
    std::ofstream(root+"/Steam/config/loginusers.vdf")<<"\"users\"\n{\n\"76561197960265729\"\n{\n\"MostRecent\" \"1\"\n}\n}\n";
    require(dlopen(argv[1],RTLD_NOW|RTLD_LOCAL)!=nullptr,"load actual native Steam dylib");
    require(FluentCloudInstallHooks()==1,"install Mach-O vtable hooks in isolated process");
    size_t size=0;auto base=VtableHook::FindSteamclient(size);
    auto remote=VtableHook::FindVtableByRTTIName("18CUserRemoteStorage",base,size);
    require(remote&&remote[24]==(void*)&hook_IsCloudEnabledForApp,"cloud-enabled hook uses verified ARM64 slot 24");
    CloudHooks::SetOriginalIsCloudEnabled((void*)&cloudOff);
    require(hook_IsCloudEnabledForApp(nullptr,480)&&!hook_IsCloudEnabledForApp(nullptr,481),"cloud-enabled allowlist and passthrough");
    require(!CloudIntercept::IsNamespaceApp(484),"automatic scope excludes explicit opt-outs");
    std::ofstream(root+"/macsteam.yaml")<<initialApps<<"  - 482 # Newly enabled\n";
    require(CloudIntercept::IsNamespaceApp(482),"new macSteam main game joins without restart");
    std::ofstream(root+"/macsteam.yaml")<<initialApps;
    require(!CloudIntercept::IsNamespaceApp(482),"removed main game leaves without restart");
    SteamKvInjector::ResolvedKvAddrs kv{};require(SteamProfile::ResolveKv(base,size,kv),"resolve guarded macOS KV helpers");
    // Synthetic engine/cache/app-info in this isolated process; no Steam IPC or account state.
    alignas(16) unsigned char engine[0x1700]={}, node[32]={}, appInfo[96]={}, kvRoot[32]={};
    auto cache=engine+kv.appInfoCacheOffset;
    *(int32_t*)(node+0)=-1;*(int32_t*)(node+4)=-1;*(uint32_t*)(node+16)=480;
    *(void**)(node+24)=appInfo;*(void**)(cache+RuntimeProfile::Get(base).appInfoNodes)=node;*(void**)(appInfo+0x40)=kvRoot;
    appInfo[0x20]=0xa5; // distinguish fixture from the empty app-cache digest
    auto find=(void*(*)(void*,const char*,uint8_t,void*))kv.kvFindKey;
    auto getU64=(uint64_t(*)(void*,uint64_t,void*))kv.kvGetUint64;
    auto getInt=(int(*)(void*,int,void*))kv.kvGetInt;
    auto ufs=find(kvRoot,"ufs",1,nullptr);require(ufs,"create real Steam KV subsection");
    auto symbol=(uint32_t*)(base+RuntimeProfile::Get(base).ufsSymbol);auto oldSymbol=*symbol;*symbol=*(uint32_t*)((char*)ufs+16)&0x1ffffff;
    auto priorEngine=*kv.globalEnginePtrPtr;*kv.globalEnginePtrPtr=engine;
    uint64_t quota=0;uint32_t maxFiles=0;
    require(SteamKvInjector::InjectAppQuota(480,1024*1024,128),"inject native UFS quota");
    require(SteamKvInjector::ReadAppQuota(480,quota,maxFiles)&&quota==1024*1024&&maxFiles==128,"read injected quota through real app cache helpers");
    require(SteamKvInjector::InjectAppQuota(480,1,1)&&SteamKvInjector::ReadAppQuota(480,quota,maxFiles)&&quota==1024*1024&&maxFiles==128,"preserve existing valid quota");
    require(SteamKvInjector::EnsureMaxNumFilesFloor(480,256,2*1024*1024),"raise quota and file count floor");
    require(getU64(find(ufs,"quota",0,nullptr),0,nullptr)==2*1024*1024&&getInt(find(ufs,"maxnumfiles",0,nullptr),0,nullptr)==256,"verify raised quota and file count");
    require(SteamKvInjector::InjectSaveFiles(480,{{"MacAppSupport","FixtureGame","*.sav",true,2}}),"inject native savefiles rules");
    auto savefiles=find(ufs,"savefiles",0,nullptr);require(savefiles&&find(savefiles,"0",0,nullptr),"savefiles child exists");
    require(!SteamKvInjector::InjectAppQuota(481,1024,10),"missing app-info is not synthesized");
    *kv.globalEnginePtrPtr=priorEngine;*symbol=oldSymbol;
    puts("PASS: real macOS KV quota/read/floor/savefiles helpers against synthetic isolated app cache; cloud-enabled 480 allowlist / 481 passthrough.");
    auto reqVT=VtableHook::FindVtableByRTTIName("35CCloud_GetAppFileChangelist_Request",base,size);
    auto respVT=VtableHook::FindVtableByRTTIName("36CCloud_GetAppFileChangelist_Response",base,size);
    require(reqVT&&respVT,"resolve real Steam protobuf vtables");
    auto request=((void*(*)(void*))reqVT[3])(nullptr);auto response=((void*(*)(void*))respVT[3])(nullptr);
    auto parse=(bool(*)(void*,const void*,int))(base+RuntimeProfile::parse(base));
    unsigned char request480[]={8,0xe0,3};
    unsigned char request481[]={8,0xe1,3};
    CloudHooks::SetOriginals((void*)&passthrough,nullptr,nullptr);
    require(parse(request,request481,3),"parse control request");int flags[70]={};
    require(hook_BYieldingSend(nullptr,"Cloud.GetAppFileChangelist#1",request,response,flags)==777,"unselected AppID passes through unchanged");
    require(parse(request,request480,3),"parse scoped request");
    auto transport=VtableHook::FindVtableByRTTIName("30CClientUnifiedServiceTransport",base,size);
    require(transport!=nullptr,"resolve installed transport vtable");
    require(transport[5]==(void*)&hook_BYieldingSend,"real transport vtable points to macOS hook");
    auto invoke=(int(*)(void*,const char*,void*,void*,int*))transport[5];
    if(failedProvider) {
        require(invoke(nullptr,"Cloud.GetAppFileChangelist#1",request,response,flags)==1&&flags[3]==2,"unavailable provider returns failure, never local-only success");
        auto status=Json::Parse("{"+CloudHooks::StatusJSONFields().substr(1)+"}");
        require(!status["cloudReady"].boolean()&&status["cloudFailures"].integer()==1,"provider failure is reported in runtime status");
        FluentCloudRemoveHooks();puts("PASS: unavailable provider fails closed with observable error; no Steam IPC or real save access.");return 0;
    }
    require(invoke(nullptr,"Cloud.GetAppFileChangelist#1",request,response,flags)==1&&flags[3]==1,"managed RPC returned success through patched vtable");
    require(((size_t(*)(void*))respVT[9])(response)>0,"response is a populated real Steam protobuf object");
    LocalDiskProvider provider;require(provider.Init(root+"/provider"),"initialize folder provider");
    const unsigned char save[]="isolated-cloud-save";std::vector<uint8_t> read;
    require(provider.Upload("1/480/test.bin",save,sizeof(save)),"upload isolated blob");
    require(provider.Download("1/480/test.bin",read)&&read.size()==sizeof(save)&&!memcmp(save,read.data(),read.size()),"download and compare bytes");
    require(!provider.Upload("../../escape.bin",save,sizeof(save)),"reject folder traversal");
    auto upload=http("PUT","/upload/1/480/loopback.bin","cloud-loopback-bytes");
    require(upload.starts_with("HTTP/1.1 200"),"same-process macOS socket authorization and upload");
    auto download=http("GET","/download/1/480/loopback.bin");
    require(download.starts_with("HTTP/1.1 200")&&download.ends_with("cloud-loopback-bytes"),"loopback blob download equality");
    require(http("GET","/download/1/480/%252e%252e/escape").starts_with("HTTP/1.1 403"),"HTTP encoded traversal rejected");
    // Entire save protocol against a disposable folder, not just a disk-provider API.
    const std::string payload("binary\0save\xff",12),filename="fixture/slot.bin";
    auto sha=FileUtil::SHA1(reinterpret_cast<const uint8_t*>(payload.data()),payload.size());
    PB::Writer batchRequest;batchRequest.WriteVarint(1,480);batchRequest.WriteString(3,filename);
    auto batch=CloudIntercept::HandleBeginBatch(480,fields(batchRequest));
    auto batchFields=fields(batch.body);auto batchID=PB::FindField(batchFields,1);
    require(batch.eresult==1&&batchID&&batchID->varintVal,"begin real save batch");
    const auto batchNumber=batchID->varintVal;
    PB::Writer uploadRequest;uploadRequest.WriteVarint(1,480);uploadRequest.WriteVarint(2,payload.size());uploadRequest.WriteVarint(3,payload.size());
    uploadRequest.WriteBytes(4,sha.data(),sha.size());uploadRequest.WriteVarint(5,1700000000);uploadRequest.WriteString(6,filename);
    auto begin=CloudIntercept::HandleBeginFileUpload(480,fields(uploadRequest));
    require(begin.eresult==1&&begin.body.Size()>0,"begin file upload produces HTTP descriptor");
    require(http("PUT","/upload/1/480/"+filename,payload).starts_with("HTTP/1.1 200"),"batch upload binary bytes");
    PB::Writer commitRequest;commitRequest.WriteVarint(1,1);commitRequest.WriteVarint(2,480);commitRequest.WriteString(4,filename);
    auto committed=CloudIntercept::HandleCommitFileUpload(480,fields(commitRequest));auto committedFields=fields(committed.body);
    require(PB::FindField(committedFields,1)&&PB::FindField(committedFields,1)->varintVal==1,"commit acknowledges durable upload");
    PB::Writer completeRequest;completeRequest.WriteVarint(1,480);completeRequest.WriteVarint(2,batchNumber);completeRequest.WriteVarint(3,1);
    require(CloudIntercept::HandleCompleteBatch(480,fields(completeRequest)).eresult==1,"complete save batch");
    CloudStorage::WaitForPendingPublish(1,480);
    auto published=CloudStorage::FetchCloudStateForServe(1,480);
    require(published.status==CloudStorage::StateFetchStatus::Ok&&published.state.files.count(filename)&&published.state.files.at(filename).sha==sha,"published folder manifest records matching SHA");
    PB::Writer downloadRequest;downloadRequest.WriteVarint(1,480);downloadRequest.WriteString(2,filename);
    auto fileDownload=CloudIntercept::HandleFileDownload(480,fields(downloadRequest));auto downloadFields=fields(fileDownload.body);
    require(fileDownload.eresult==1&&PB::GetString(downloadFields,8)=="/download/1/480/"+filename,"download RPC returns matching loopback path");
    require(http("GET",std::string(PB::GetString(downloadFields,8))).ends_with(payload),"complete upload/publish/download preserves binary save bytes");
    puts("PASS: full isolated save batch -> HTTP upload -> commit -> folder manifest -> RPC download, binary SHA verified.");
    std::filesystem::create_directories(root+"/Steam/userdata/1/480/remote");
    std::ofstream(root+"/Steam/userdata/1/480/remote/save.bin")<<"private fixture";
    auto inventory=Json::Parse(SaveInventory::Scan("480"));
    require(inventory["success"].boolean()&&inventory["files"].size()==1,"read-only selected save inventory");
    require(!Json::Parse(SaveInventory::Scan("480,bad"))["success"].boolean(),"invalid inventory scope rejected");
    auto nativeRoots=AutoCloudScan::GetRootTokenDirectories(root+"/Steam",481,1);
    require(nativeRoots.count("%MacAppSupport%")&&!nativeRoots.count("%LinuxHome%"),"native macOS root mapping excludes Linux roots");
    auto external=root+"/ExternalLibrary";
    std::filesystem::create_directories(external+"/steamapps/compatdata/482/pfx/drive_c/users/steamuser/AppData/Local");
    std::filesystem::create_directories(root+"/Steam/steamapps");
    std::ofstream(root+"/Steam/steamapps/libraryfolders.vdf")<<"\"libraryfolders\"\n{\n\"1\"\n{\n\"path\" \""<<external<<"\"\n}\n}\n";
    auto wineRoots=AutoCloudScan::GetRootTokenDirectories(root+"/Steam",482,1);
    require(wineRoots["%WinAppDataLocal%"]==external+"/steamapps/compatdata/482/pfx/drive_c/users/steamuser/AppData/Local/"&&!wineRoots.count("%MacHome%"),"external-library NotProton prefix maps Windows roots only");
    std::filesystem::create_directories(root+"/Steam/config");
    std::ofstream(root+"/Steam/config/config.vdf")<<"\"InstallConfigStore\"\n{\n\"Software\"\n{\n\"Valve\"\n{\n\"Steam\"\n{\n\"CompatToolMapping\"\n{\n\"482\"\n{\n\"name\" \"fluent-proton-free\"\n}\n}\n}\n}\n}\n}\n";
    std::ofstream(external+"/steamapps/appmanifest_482.acf")<<"\"AppState\" {}";
    auto absentFreeRoots=AutoCloudScan::GetRootTokenDirectories(root+"/Steam",482,1);
    require(absentFreeRoots["%WinAppDataLocal%"]==external+"/steamapps/compatdata/482/fluent-free/pfx/drive_c/users/steamuser/AppData/Local/"&&!absentFreeRoots.count("%MacHome%"),"missing free prefix never resolves to paid or native saves");
    std::filesystem::create_directories(external+"/steamapps/compatdata/482/fluent-free/pfx/drive_c/users/steamuser/AppData/Local");
    auto freeRoots=AutoCloudScan::GetRootTokenDirectories(root+"/Steam",482,1);
    require(freeRoots["%WinAppDataLocal%"]==external+"/steamapps/compatdata/482/fluent-free/pfx/drive_c/users/steamuser/AppData/Local/","free runtime saves stay in the selected external-library prefix");
    require(AutoCloudUtil::AutoCloudRuleMatchesCurrentPlatform(2)&&!AutoCloudUtil::AutoCloudRuleMatchesCurrentPlatform(8),"macOS AutoCloud platform mask");
    auto status=Json::Parse("{"+CloudHooks::StatusJSONFields().substr(1)+"}");
    require(status["cloudReady"].boolean()&&status["cloudProvider"].str()=="folder"&&status["cloudRequests"].integer()>0,"runtime status reports actual folder and requests");
    std::ofstream(root+"/CloudRedirect/config.json")<<config<<"\n";
    require(invoke(nullptr,"Cloud.GetAppFileChangelist#1",request,response,flags)==1&&flags[3]==2,"changed config blocks stale provider until restart");
    std::ofstream(root+"/CloudRedirect/config.json")<<config;
    require(invoke(nullptr,"Cloud.GetAppFileChangelist#1",request,response,flags)==1&&flags[3]==1,"restoring loaded config restores valid RPC handling");
    puts("PASS: macOS loopback HTTP authorization/upload/download/traversal and macOS/NotProton external-library root mapping.");
    puts("PASS: real ARM64 Steam protobuf, Mach-O vtable installation, selected-AppID RPC interception, unselected-AppID passthrough, local provider roundtrip and traversal rejection. No Steam IPC session or real save access.");
    FluentCloudRemoveHooks();
    puts("PASS: hooks restored and all cloud worker threads shut down normally.");
    return 0;
}
