#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libkern/OSCacheControl.h>
#include <unistd.h>
#include <atomic>
#include <thread>
#include <vector>
#include <cstring>
#include <cstdio>
#include <cstdlib>
extern "C" int DobbyCodePatch(void*, uint8_t*, uint32_t);
void check(bool value) { if (!value) std::abort(); }
int main() {
    const auto size = getpagesize();
    mach_vm_address_t memory = 0;
    check(mach_vm_allocate(mach_task_self(), &memory, size * 2, VM_FLAGS_ANYWHERE) == KERN_SUCCESS);
    // Two ARM64 functions on the same page, plus a cross-page instruction pair.
    uint32_t code[] = {0x528000e0, 0xd65f03c0}; // mov w0,#7; ret
    std::memcpy(reinterpret_cast<void*>(memory), code, sizeof(code));
    std::memcpy(reinterpret_cast<void*>(memory + 64), code, sizeof(code));
    std::memcpy(reinterpret_cast<void*>(memory + size - 4), code, sizeof(code));
    sys_icache_invalidate(reinterpret_cast<void*>(memory), size * 2);
    check(mach_vm_protect(mach_task_self(), memory, size * 2, false, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS);
    std::atomic<bool> stop{false}; std::atomic<unsigned long> calls{0};
    std::vector<std::thread> workers;
    for (int i = 0; i < 4; ++i) workers.emplace_back([&] {
        auto neighbor = reinterpret_cast<int(*)()>(memory + 64);
        while (!stop) { check(neighbor() == 7); ++calls; }
    });
    for (int i = 0; i < 2000; ++i) {
        code[0] = i % 2 ? 0x528000e0 : 0x52800100; // 7 or 8
        check(DobbyCodePatch(reinterpret_cast<void*>(memory), reinterpret_cast<uint8_t*>(code), sizeof(code)) == 0);
        check(reinterpret_cast<int(*)()>(memory)() == (i % 2 ? 7 : 8));
        check(DobbyCodePatch(reinterpret_cast<void*>(memory + size - 4), reinterpret_cast<uint8_t*>(code), sizeof(code)) == 0);
        check(reinterpret_cast<int(*)()>(memory + size - 4)() == (i % 2 ? 7 : 8));
    }
    stop = true; for (auto& worker : workers) worker.join();
    check(calls > 0);
    check(DobbyCodePatch(reinterpret_cast<void*>(1), reinterpret_cast<uint8_t*>(code), sizeof(code)) == -1);
    mach_vm_deallocate(mach_task_self(), memory, size * 2);
    printf("PASS: 4000 executable page replacements, four concurrent neighbor readers (%lu calls), cross-page patches and invalid address rejection.\n", calls.load());
}
