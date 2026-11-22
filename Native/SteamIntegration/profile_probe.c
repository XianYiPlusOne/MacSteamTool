#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include "core/arch.h"
#include "resolver/resolver.h"
#include "core/macho.h"
#include "util/log.h"
int main(int argc, char **argv) {
    if(argc != 3) return 2;
    sx_log_level=3;
    if(!dlopen(argv[1], RTLD_NOW|RTLD_LOCAL)) { fprintf(stderr,"%s\n",dlerror()); return 3; }
    const struct mach_header_64 *mh=NULL; intptr_t slide=0;
    if(sx_wait_for_image_ex("steamclient.dylib",100,&mh,&slide,NULL,0)) return 4;
    sx_sigdb_t db={0}; if(sx_sigdb_load(argv[2],&db)) return 5;
    int required=0;
    for(int i=0;i<db.sig_count;i++) { if(!db.signatures[i].deprecated) required++; }
    sx_resolve_result_t result={0};
    int found=sx_resolve_all_ex(mh,slide,argv[1],&db,&result);
    printf("READ-ONLY: %d/%d required signatures resolved using UUID and exact entry guards; no hooks installed\n",found,required);
    for(int i=0;i<result.count;i++) printf("RESOLVED %s 0x%lx\n",result.entries[i].name,result.entries[i].address ? result.entries[i].address-slide : 0);
    if(found!=required) return 1;
    sx_resolve_result_free(&result);
    db.module_uuid[0] = db.module_uuid[0]=='0' ? '1' : '0';
    if(sx_resolve_all_ex(mh,slide,argv[1],&db,&result)!=0) return 6;
    sx_resolve_result_free(&result); sx_sigdb_free(&db);
    if(sx_sigdb_load(argv[2],&db)) return 7;
    if(!db.sig_count) return 9;
    strcpy(db.arch, !strcmp(SX_ARCH_NAME,"arm64") ? "x86_64" : "arm64");
    if(sx_resolve_all_ex(mh,slide,argv[1],&db,&result)!=0) return 10;
    sx_resolve_result_free(&result);
    strcpy(db.arch,SX_ARCH_NAME);
    db.signatures[0].entry_hex[0]=db.signatures[0].entry_hex[0]=='0'?'1':'0';
    if(sx_resolve_all_ex(mh,slide,argv[1],&db,&result)!=required-1) return 8;
    puts("PASS: all exact sites validated; changed architecture, UUID and entry rejected without hooks");
    sx_resolve_result_free(&result); sx_sigdb_free(&db); return 0;
}
