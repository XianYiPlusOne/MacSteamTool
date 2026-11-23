// Include the production callbacks. Unused hooks are removed by dead stripping.
#include "../hooks/hook_compat.c"
#include <stdlib.h>
#include <libkern/OSCacheControl.h>
#include <sys/mman.h>
#include <unistd.h>

int np_log_level = -1;
FILE *np_log_file = NULL;
static int test_registration_count;
void np_compat_force_enable(void *manager) { ((unsigned char *)manager)[0x810] = 1; }
void np_compat_register_crossover(void *manager) { if (manager) ++test_registration_count; }
extern bool np_test_enabled(void *manager, uint32_t appid);
static const char *test_directory = "/isolated/crossover";
uint32_t np_compat_tool_off(uint32_t offset) { return offset < 0x58 ? offset : offset + 8; }
const char *np_compat_tool_dir(void) { return test_directory; }
const char *np_compat_tool_commandline(void) { return "/run %verb%"; }

extern int np_test_oslist(uint64_t result, void *tool);
extern void np_test_oslist_gate(void);
extern const char *np_test_redirect(void *tool);
extern void np_test_redirect_gate(void);
#define CHECK(c, message) do { if (!(c)) { fprintf(stderr,"FAIL: %s\n",message); return 1; } } while (0)

// Test-only: this page contains no executing thread or application code.
// Rosetta retains translations across mach_vm_remap; force a new translation.
static int refresh_fixture(void *code, size_t size) {
    return mprotect(code,size,PROT_READ|PROT_WRITE) ||
           mprotect(code,size,PROT_READ|PROT_EXEC);
}

int main(void) {
    unsigned char *tool = calloc(1,0x138);
    CHECK(tool, "allocate synthetic tool");
    *(uint32_t *)(tool+0x68) = 42;
    *(uint32_t *)(tool+0x20) = 99;
    np_dobby_ctx_t context = {0};
    context.general.regs.r12 = (uintptr_t)tool;
    context.general.regs.rbx = 0x12345678;
    context.flags = 0x202;
    instrument_oslist_override_gate(NULL,&context);
    CHECK(context.general.regs.rax == 1 && context.general.regs.r12 == (uintptr_t)tool &&
          context.general.regs.rbx == 0x12345678 && context.flags == 0x202, "OS-list changes only RAX, leaves flags for original TEST");
    context.general.regs.rax = 0x1234;
    instrument_oslist_override_gate(NULL,&context);
    CHECK(context.general.regs.rax == 0x1234, "nonzero OS-list result preserved");

    context.general.regs.rax = (uintptr_t)tool;
    test_directory = NULL;
    instrument_resolver_local_redirect(NULL,&context);
    CHECK(*(uint32_t *)(tool+0x68) == 42, "no local runner means no tool mutation");
    test_directory = "/isolated/crossover";
    instrument_resolver_local_redirect(NULL,&context);
    CHECK(context.general.regs.rax == (uintptr_t)tool && *(uint32_t *)(tool+0x68) == 0 &&
          *(uint32_t *)(tool+4) == 2 && *(uint32_t *)(tool+0x20) == 0 &&
          !strcmp(*(const char **)(tool+0x60),test_directory) &&
          !strcmp(*(const char **)(tool+0x18),"/run %verb%"), "Intel redirect writes correct tool fields without changing RAX");
    unsigned char snapshot[0x138]; memcpy(snapshot,tool,sizeof(snapshot));
    instrument_resolver_local_redirect(NULL,&context);
    CHECK(!memcmp(snapshot,tool,sizeof(snapshot)), "already-local tool is unchanged");
    context.general.regs.rax = 0;
    instrument_resolver_local_redirect(NULL,&context);

    size_t page_size = (size_t)getpagesize();
    unsigned char *code = mmap(NULL,page_size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    CHECK(code != MAP_FAILED,"allocate executable fixture");
    memcpy(code,(const void *)np_test_oslist,128);
    memcpy(code+256,(const void *)np_test_redirect,128);
    CHECK(!mprotect(code,page_size,PROT_READ|PROT_EXEC),"make fixture executable");
    int (*run_oslist)(uint64_t,void *) = (void *)code;
    const char *(*run_redirect)(void *) = (void *)(code+256);
    void *oslist_gate = code+((uintptr_t)np_test_oslist_gate-(uintptr_t)np_test_oslist);
    void *redirect_gate = code+256+((uintptr_t)np_test_redirect_gate-(uintptr_t)np_test_redirect);

    CHECK(run_oslist(0,tool)==0 && run_oslist(5,tool)==1,"unmodified synthetic OS-list behavior");
    CHECK(!DobbyInstrument(oslist_gate,(dobby_instrument_callback_t)instrument_oslist_override_gate), "install production OS-list callback on owned x86 fixture");
    CHECK(!refresh_fixture(code,page_size), "refresh owned translation after installation");
    int zero = run_oslist(0,tool), nonzero = run_oslist(5,tool);
    CHECK(zero == 1 && nonzero == 1, "Dobby x86 context redirects OS-list test correctly");
    CHECK(!DobbyDestroy(oslist_gate), "restore owned OS-list code");
    CHECK(!refresh_fixture(code,page_size), "refresh owned translation");
    CHECK(run_oslist(0,tool) == 0, "OS-list code restored");

    *(uint32_t *)(tool+0x68) = 42;
    CHECK(run_redirect(tool) == NULL, "unmodified synthetic remote-tool path");
    CHECK(!DobbyInstrument(redirect_gate,(dobby_instrument_callback_t)instrument_resolver_local_redirect), "install production redirect callback on owned x86 fixture");
    CHECK(!refresh_fixture(code,page_size), "refresh owned translation");
    CHECK(run_redirect(tool) == test_directory && *(uint32_t *)(tool+0x68) == 0, "Dobby x86 callback takes original local-tool branch");
    CHECK(!DobbyDestroy(redirect_gate), "restore owned redirect code");
    CHECK(!refresh_fixture(code,page_size), "refresh owned translation");
    *(uint32_t *)(tool+0x68) = 42;
    CHECK(run_redirect(tool) == NULL, "redirect code restored");
    CHECK(!mprotect(code,page_size,PROT_READ|PROT_WRITE),"prepare replacement fixture");
    memcpy(code+512,(const void *)np_test_enabled,32);
    CHECK(!mprotect(code,page_size,PROT_READ|PROT_EXEC),"make replacement fixture executable");
    bool (*run_enabled)(void *,uint32_t) = (void *)(code+512);
    unsigned char manager[0x900] = {0};
    CHECK(!run_enabled(manager,300),"original compatibility switch is off");
    CHECK(!DobbyHook(code+512,(void *)hook_CCompatManager_BIsEnabled,&orig_CCompatManager_BIsEnabled),"install production compatibility replacement");
    CHECK(!refresh_fixture(code,page_size),"refresh owned replacement translation");
    CHECK(run_enabled(manager,300) && test_registration_count == 1 && manager[0x810] == 1,
          "production replacement registers runner, forces enable and calls original trampoline");
    CHECK(!DobbyDestroy(code+512),"restore compatibility replacement");
    CHECK(!refresh_fixture(code,page_size),"refresh restored replacement translation");
    manager[0x810] = 0;
    CHECK(!run_enabled(manager,300) && test_registration_count == 1,"replacement removal restores original behavior");
    munmap(code,page_size);
    free(tool);
    puts("PASS: production Intel callbacks, register preservation, real Dobby instrumentation, replacement trampolines and restoration on owned assembly fixtures");
    return 0;
}
