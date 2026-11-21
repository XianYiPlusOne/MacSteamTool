#include <assert.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../MacSteam/src/config/config.h"
static time_t clock_value = 100;
static time_t test_time(time_t *p) { if(p) *p=clock_value; return clock_value; }
#define SX_REFRESH_TEST 1
#define time test_time
#include "../MacSteam/src/core/hot_refresh.c"
#undef time
int sx_log_level = -1;
FILE *sx_log_file;
static int fired;
int sx_reconcile_can_refresh(void) { return 1; }
int sx_reconcile_login_observed(void) { return 1; }
void sx_reconcile_set_library_refresh_apps(const int *a, int n) { assert(a && n); }
void sx_reconcile_arm_after_inject(void) {}
void sx_reconcile_arm_library_refresh(void) {}
int sx_reconcile_fire_library_refresh(void *p) { fired++; return p != NULL; }
static void write_config(const char *s) { FILE *f=fopen(config_path,"w"); assert(f); fputs(s,f); fclose(f); }
static void send_request(int number, int bad_hash) {
    size_t size; unsigned char digest[32]; void *data=sx_slurp_file(config_path,&size);
    CC_SHA256(data,(CC_LONG)size,digest); free(data);
    char hash[65]; for(int i=0;i<32;i++) snprintf(hash+2*i,3,"%02x",digest[i]);
    if(bad_hash) hash[0]=hash[0]=='0'?'1':'0';
    char path[1200]; snprintf(path,sizeof(path),"%s.refresh-request",config_path);
    FILE *f=fopen(path,"w"); assert(f);
    fprintf(f,"00000000-0000-0000-0000-%012d %d %s\n",number,getpid(),hash); fclose(f);
    clock_value++; sx_hot_refresh_poll((void *)1);
}
int main(void) {
    char dir[]="/tmp/fluent-refresh-test.XXXXXX"; assert(mkdtemp(dir));
    char path[1024]; snprintf(path,sizeof(path),"%s/config.yaml",dir);
    setenv("MACSTEAM_CONFIG",path,1); sx_hot_refresh_start(); sx_hot_refresh_login(1);
    write_config("Apps:\n  - 480\nPackageIds:\n  - 20200\n");
    static sx_config_t initial; assert(!sx_config_load(path,&initial)); sx_config_current=&initial;
    write_config("Apps:\n  - 480\n  - 570\nPackageIds:\n  - 20200\n");
    send_request(1,1); assert(!fired && sx_config_current==&initial);
    send_request(2,0); assert(fired==1 && sx_config_has_app(sx_config_current,570));
    send_request(2,0); assert(fired==1); // replay cannot refresh twice
    write_config("Apps:\n  - 570\nPackageIds:\n  - 20200\n");
    send_request(3,0); assert(fired==1 && sx_config_has_app(sx_config_current,480));
    write_config("Apps:\n  - 480\n  - 570\nPackageIds:\n  - 20200\n  - 20201\n");
    send_request(4,0); assert(fired==1); // new license packages require login
    snapshots=32; send_request(5,0); assert(fired==1);
    sx_config_free(&initial);
    for(int i=0;i<32;i++) if(retained[i]) { sx_config_free(retained[i]); free(retained[i]); }
    unlink(path); snprintf(path,sizeof(path),"%s/config.yaml.refresh-request",dir); unlink(path);
    snprintf(path,sizeof(path),"%s/config.yaml.refresh-result",dir); unlink(path); rmdir(dir);
    puts("PASS: config hash, additive reload, replay, removal fallback, memory cap");
}
