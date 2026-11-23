// Isolated client ABI/registration test. No hooks, Steam session or config writes.
#include "../resolver/resolver.h"
#include "../resolver/anchor.h"
#include "../core/macho.h"
#include "../feats/webui.h"
#include "../feats/compatsvc.h"
#include "../util/cxx_string.h"
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#define CHECK(c,m) do { if (!(c)) { fprintf(stderr,"FAIL: %s\n",m); return 1; } } while(0)

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    CHECK(dlopen(argv[1], RTLD_NOW|RTLD_LOCAL), "load client in isolated process");
    const struct mach_header_64 *mh = NULL;
    intptr_t slide = 0;
    CHECK(!np_await_image("steamclient.dylib",100,&mh,&slide,NULL,0),"find mapped client");
    np_sigdb_t db = {0}; np_resolve_result_t resolved = {0};
    CHECK(!np_load_profile(argv[2],&db),"load shipped Intel profile");
    int required = np_required_for_module(&db,"steamclient.dylib");
    CHECK(required >= 22,"complete compatibility and WebUI contracts");
    CHECK(np_resolve_signatures(mh,slide,&db,"steamclient.dylib",&resolved)==required,"all complete-function hashes and boundaries match");
    np_free_resolution(&resolved);
    db.module_uuid[0] ^= 1;
    CHECK(!np_resolve_signatures(mh,slide,&db,"steamclient.dylib",&resolved),"reject wrong UUID");
    db.module_uuid[0] ^= 1;
    strcpy(db.arch,"arm64");
    CHECK(!np_resolve_signatures(mh,slide,&db,"steamclient.dylib",&resolved),"reject wrong architecture");
    strcpy(db.arch,"x86_64");
    for (int i=0;i<db.sig_count;++i) {
        db.signatures[i].function_sha256[0] ^= 1;
        CHECK(np_resolve_signatures(mh,slide,&db,"steamclient.dylib",&resolved)==required-1,"reject mismatched full function hash without fallback");
        CHECK(!np_lookup_address(&resolved,db.signatures[i].name),"rejected function unavailable");
        np_free_resolution(&resolved);
        db.signatures[i].function_sha256[0] ^= 1;
    }
    db.schema_version = 3;
    CHECK(!np_resolve_signatures(mh,slide,&db,"steamclient.dylib",&resolved),"Intel rejects legacy scan-based profiles");
    db.schema_version = 4;
    db.signatures[0].function_start++;
    strcpy(db.signatures[0].aob_hex,"55 48 89 E5");
    CHECK(np_resolve_signatures(mh,slide,&db,"steamclient.dylib",&resolved)==required-1,"wrong function boundary cannot fall back to byte scanning");
    np_free_resolution(&resolved);
    db.signatures[0].function_start--;
    db.signatures[0].aob_hex[0] = 0;
    CHECK(np_resolve_signatures(mh,slide,&db,"steamclient.dylib",&resolved)==required,"restore reviewed profile");
    CHECK(np_webui_bind_intel(slide,&resolved),"bind Intel WebUI contract");
    CHECK(np_webui_init(mh,slide,np_lookup_address(&resolved,"CWebUIJobDispatcher::RegisterHandler"),
          np_lookup_address(&resolved,"CWebUITransport::DispatchJob"),
          np_lookup_address(&resolved,"CWebUIMsgJob::SendResponse")),"initialize real client WebUI registry");
    uintptr_t text; size_t size;
    CHECK(!np_find_section(mh,slide,"__TEXT","__text",&text,&size),"find code section");
    uintptr_t request_vptr = np_rtti_vptr(mh,slide,text,size,"37CCompatManager_GetCompatTools_Request");
    uintptr_t specify_vptr = np_rtti_vptr(mh,slide,text,size,"40CCompatManager_SpecifyCompatTool_Request");
    CHECK(request_vptr && specify_vptr,"real Intel protobuf vtables");
    uintptr_t request = np_webui_new_message(request_vptr);
    const unsigned char appid_wire[] = {0x08,0xac,0x02}; // appid 300
    CHECK(request && np_webui_parse_into(request,appid_wire,sizeof(appid_wire)),"parse GetCompatTools request");
    CHECK((*(uint32_t *)(request+16)&1) && *(uint32_t *)(request+24)==300,"Intel request field offsets");
    uintptr_t specify = np_webui_new_message(specify_vptr);
    const unsigned char specify_wire[] = {0x08,0xac,0x02,0x12,3,'a','b','c'};
    CHECK(specify && np_webui_parse_into(specify,specify_wire,sizeof(specify_wire)),"parse SpecifyCompatTool request");
    CHECK((*(uint32_t *)(specify+16)&2) && *(uint32_t *)(specify+32)==300,"Intel specify field offsets");
    CHECK(!strcmp(np_steam_string_field(specify+24),"abc"),"Intel short-string layout");
    const char long_name[] = "notproton.crossover.a-long-runtime-identifier";
    unsigned char long_wire[128] = {0x12,sizeof(long_name)-1};
    memcpy(long_wire+2,long_name,sizeof(long_name)-1);
    CHECK(np_webui_parse_into(specify,long_wire,sizeof(long_name)+1),"parse heap-backed tool name");
    CHECK(!strcmp(np_steam_string_field(specify+24),long_name),"Intel long-string layout");
    // Generated protobuf virtual slot 1 is the deleting destructor.
    ((void (*)(uintptr_t))(*(uintptr_t *)(request_vptr+8)))(request);
    ((void (*)(uintptr_t))(*(uintptr_t *)(specify_vptr+8)))(specify);
    np_compatsvc_register(mh,slide,text,size);
    CHECK(np_compatsvc_routes()==NP_COMPATSVC_READY,"register compatibility routes using actual Intel message classes and job template");
    uintptr_t registry = np_webui_registry();
    uintptr_t elements = *(const uintptr_t *)(registry + 0x90);
    uint32_t bound = *(const uint32_t *)(registry + 0xa8);
    CHECK(bound < 100000, "bounded route registry");
    const char *routes[] = {"CompatManager.GetCompatTools#1", "CompatManager.SpecifyCompatTool#1",
        "NotProton.SetDefaults#1", "NotProton.SetToolDefaults#1", "NotProton.ApplyToolDefaults#1",
        "NotProton.PrefixState#1", "NotProton.RebuildPrefix#1", "NotProton.BackupAndRebuildPrefix#1", "NotProton.OpenPrefixLog#1"};
    for (size_t r=0;r<sizeof(routes)/sizeof(routes[0]);++r) {
        int matches = 0;
        for (uint32_t i=0;i<bound;++i) {
            const char *name = *(const char **)(elements + i * 48);
            if (name && !strcmp(name,routes[r])) ++matches;
        }
        if (matches != 1) fprintf(stderr,"route %s: %d matches\n",routes[r],matches);
        CHECK(matches == 1,"all compatibility routes actually appear once in client registry");
    }
    np_free_resolution(&resolved); np_free_profile(&db);
    puts("PASS: Intel runtime profile, negative checks, real WebUI registry, protobuf types and compatibility route registration; no hooks installed");
    return 0;
}
