#include "pins.h"
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <cstdlib>
void require(bool result,const char* message){if(!result){fprintf(stderr,"FAIL: %s\n",message);fflush(nullptr);_Exit(1);}printf("PASS: %s\n",message);}
int main(int argc,char** argv){
    if(argc==4 && std::strcmp(argv[1],"--exit-installed")==0){
        std::string root=argv[3];require(root.starts_with('/')&&!std::filesystem::exists(root),"fresh process-exit fixture");
        std::filesystem::create_directories(root);
        setenv("FLUENT_PINS_CONFIG",(root+"/config.yaml").c_str(),1);setenv("FLUENT_PINS_CACHE",root.c_str(),1);setenv("FLUENT_PINS_STATUS",(root+"/pins.log").c_str(),1);
        require(dlopen(argv[2],RTLD_NOW|RTLD_LOCAL),"load real client for normal process-exit regression");
        require(FluentPinsInstall()==1,"install detour before automatic process-exit cleanup");
        return 0; // Intentionally exercise atexit and dylib/C++ destructors.
    }
    if(argc==3 && std::strcmp(argv[1],"--reject-build")==0){
        require(dlopen(argv[2],RTLD_NOW|RTLD_LOCAL),"load isolated client with deliberately changed build UUID");
        require(FluentPinsInstall()==-1,"unknown Steam build refused before installing any detour");
        fflush(nullptr);_Exit(0);
    }
    require(argc==4,"usage: probe steamclient.dylib validated-621-manifest new-private-root");
    std::string root=argv[3];require(root.starts_with('/') && !std::filesystem::exists(root),"fresh isolated data root");
    std::filesystem::create_directories(root+"/cache");
    auto config=root+"/config.yaml",cache=root+"/cache",log=root+"/pins.log";
    setenv("FLUENT_PINS_CONFIG",config.c_str(),1);setenv("FLUENT_PINS_CACHE",cache.c_str(),1);setenv("FLUENT_PINS_STATUS",log.c_str(),1);
    const uint64_t gid=9044256803759256265ULL;
    auto manifest=cache+"/621_"+std::to_string(gid)+".manifest";
    std::filesystem::copy_file(argv[2],manifest);
    std::ofstream(config)<<"Apps:\n  - 480\nFluentManifestPins:\n  480:\n    621: "<<gid<<"\n";
    void* client=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);require(client,"load real ARM64 steamclient without Steam IPC");
    uintptr_t base=0;for(uint32_t i=0;i<_dyld_image_count();++i)if(std::string_view(_dyld_get_image_name(i)).ends_with("/steamclient.dylib"))base=reinterpret_cast<uintptr_t>(_dyld_get_image_header(i));
    require(base,"locate loaded client image");
    using Find=void*(*)(void*,const char*,uint8_t,void*);auto find=reinterpret_cast<Find>(base+0x1096b60);
    using Set=void(*)(void*,uint64_t);auto set=reinterpret_cast<Set>(base+0x1098644);
    alignas(16) unsigned char tree[32]={};
    set(find(tree,"621/manifests/public/gid",1,nullptr),111);
    set(find(tree,"621/manifests/public/size",1,nullptr),222);
    set(find(tree,"621/manifests/beta/gid",1,nullptr),333);
    set(find(tree,"621/manifests/beta/size",1,nullptr),444);
    set(find(tree,"622/manifests/public/gid",1,nullptr),555);
    set(find(tree,"622/manifests/public/size",1,nullptr),666);
    struct Depot {uint32_t id=621;uint32_t padding=0;uint64_t gid=0,size=0;} depot;
    using Read=bool(*)(void*,void*,const char*);auto read=reinterpret_cast<Read>(base+0x5b0394);
    require(read(&depot,tree,"public") && depot.gid==111 && depot.size==222,"real depot helper ABI and native KV selection verified");
    require(FluentPinsInstall()==1 && FluentPinsCount()==1,"production dylib installs guarded ARM64 detour and validates cache");
    require(read(&depot,tree,"public") && depot.gid==gid && depot.size>222,"pinned gid and matching manifest disk size selected through real Steam function");
    require(read(&depot,tree,"beta") && depot.gid==333 && depot.size==444,"private/beta branch passes through unchanged");
    depot.id=622;require(read(&depot,tree,"public") && depot.gid==555 && depot.size==666,"unselected depot passes through unchanged");
    depot.id=999;require(!read(&depot,tree,"public"),"missing depot metadata remains invalid");
    depot.id=621;
    std::ofstream(config)<<"Apps:\n  - 481\nFluentManifestPins:\n  480:\n    621: "<<gid<<"\n";
    FluentPinsReload();require(!FluentPinsCount() && read(&depot,tree,"public") && depot.gid==111,"disabled app pin removed by hot reload");
    std::ofstream(config)<<"Apps:\n  - 480\nFluentManifestPins:\n  480:\n    621: "<<gid<<"\n    621: 123\n";
    FluentPinsReload();require(!FluentPinsCount(),"duplicate/conflicting pin configuration fails closed");
    std::ofstream(config)<<"Apps:\n  - 480\nFluentManifestPins:\n  480:\n    621: "<<gid<<"\n";
    {std::fstream f(manifest,std::ios::in|std::ios::out|std::ios::binary);f.seekp(10);char corrupt='x';f.write(&corrupt,1);}
    FluentPinsReload();require(!FluentPinsCount(),"corrupt cached manifest cannot activate pin");
    std::filesystem::remove(manifest);std::filesystem::copy_file(argv[2],manifest);FluentPinsReload();
    require(FluentPinsCount()==1 && read(&depot,tree,"public") && depot.gid==gid,"repaired cache reactivates pin without restarting process");
    std::filesystem::remove(manifest);FluentPinsReload();require(!FluentPinsCount() && read(&depot,tree,"public") && depot.gid==111,"removed cached manifest disables pin immediately on reload");
    FluentPinsRemove();require(read(&depot,tree,"public") && depot.gid==111 && depot.size==222,"detour removal restores original real Steam behavior");
    puts("No real Steam session, downloads, games or saves were accessed.");
    fflush(nullptr);_Exit(0); // Steam's private KV allocator is process scoped; no engine shutdown is invoked.
}
