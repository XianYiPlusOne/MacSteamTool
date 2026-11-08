// Darwin code-page replacement for the pinned Apache-2.0 Dobby dependency.
// Never remove execute permission from a live page: another thread may be
// running a different function on that same 16 KiB page.
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libkern/OSCacheControl.h>
#include <cstring>
#include <cstdint>
#include <limits>
#include <mutex>
#include <unistd.h>

extern "C" int DobbyCodePatch(void* address, uint8_t* bytes, uint32_t length) {
    if (!address || !bytes || !length) return -1;
    const auto begin = reinterpret_cast<uintptr_t>(address);
    if (begin > std::numeric_limits<uintptr_t>::max() - length) return -1;
    const auto pageSize = static_cast<uintptr_t>(getpagesize());
    const auto start = begin & ~(pageSize - 1);
    if (begin + length > std::numeric_limits<uintptr_t>::max() - (pageSize - 1)) return -1;
    const auto end = (begin + length + pageSize - 1) & ~(pageSize - 1);
    const auto span = end - start;
    // One replacement also covers instructions that straddle a page boundary.
    // Serialize snapshots from this Dobby instance to preserve adjacent patches.
    static std::mutex mutex;
    std::lock_guard lock(mutex);
    const auto task = mach_task_self();
    mach_vm_address_t scratch = 0;
    if (mach_vm_allocate(task, &scratch, span, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return -1;
    struct Cleanup { mach_port_t task; mach_vm_address_t page; mach_vm_size_t size;
        ~Cleanup() { mach_vm_deallocate(task, page, size); }
    } cleanup{task, scratch, span};
    mach_vm_size_t copied = 0;
    if (mach_vm_read_overwrite(task, start, span, scratch, &copied) != KERN_SUCCESS || copied != span) return -1;
    std::memcpy(reinterpret_cast<void*>(scratch + begin - start), bytes, length);
    sys_icache_invalidate(reinterpret_cast<void*>(scratch), span);
    if (mach_vm_protect(task, scratch, span, false, VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS) return -1;
    mach_vm_address_t destination = start;
    vm_prot_t current = 0, maximum = 0;
    // The kernel replaces the mapping with an already executable page; there is
    // no writable/non-executable interval on the original mapping.
    if (mach_vm_remap(task, &destination, span, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                      task, scratch, true, &current, &maximum, VM_INHERIT_COPY) != KERN_SUCCESS) return -1;
    sys_icache_invalidate(address, length);
    return 0;
}
