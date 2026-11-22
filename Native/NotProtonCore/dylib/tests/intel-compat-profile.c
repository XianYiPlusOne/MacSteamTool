// Isolated, read-only checks against a local client. Never installs hooks.
#include "../feats/intel_compat.h"
#include "../core/macho.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(c, message) do { if (!(c)) { fprintf(stderr,"FAIL: %s\n",message); return 1; } } while (0)

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    CHECK(dlopen(argv[1], RTLD_NOW | RTLD_LOCAL), "load local Steam image");
    const struct mach_header_64 *mh = NULL;
    intptr_t slide = 0;
    CHECK(!np_await_image("steamclient.dylib",100,&mh,&slide,NULL,0), "find mapped image");
    np_resolved_t entries[] = {
        {"CCompatManager::BIsCompatibilityToolEnabled", 0x66d1f0 + (uintptr_t)slide},
        {"CCompatManager::GetWildcardMapping", 0x66ca62 + (uintptr_t)slide},
        {"CCompatManager::WindowsOnlyLookup", 0x66cf7c + (uintptr_t)slide},
        {"CCompatManager::GetOSListOverrideForApp.oslist_gate", 0x66cd29 + (uintptr_t)slide},
        {"CCompatManager::ResolveCompatToolForApp.local_redirect", 0x66ce14 + (uintptr_t)slide},
    };
    np_resolve_result_t resolved = {.items=entries,.used=5,.cap=5};
    np_intel_compat_layout_t layout, zero = {0};
    CHECK(np_intel_compat_from_image(mh,slide,&resolved,&layout), "reviewed UUID, function boundaries and five complete function hashes");
    CHECK(layout.tool_shift == 8 && layout.enabled_offset == 0x810 && layout.windows_only_offset == 0x698, "Intel object fields");
    CHECK(np_intel_compat_allows(&layout,entries[3].name,entries[3].site), "OS-list gate allowed");
    CHECK(np_intel_compat_allows(&layout,entries[4].name,entries[4].site), "local redirect gate allowed");
    CHECK(!np_intel_compat_allows(&layout,entries[3].name,entries[4].site), "wrong gate rejected");
    CHECK(!np_intel_compat_allows(&layout,"CClientDRMDownloadJob::unknown",entries[3].site), "unported prehooks remain disabled");
    CHECK(!np_intel_compat_allows(&zero,entries[3].name,entries[3].site), "unbound callbacks remain disabled");

    uintptr_t text; size_t size;
    CHECK(!np_find_section(mh,slide,"__TEXT","__text",&text,&size), "bounded code section");
    unsigned char *copy = malloc(size);
    CHECK(copy, "allocate isolated code copy");
    memcpy(copy,(const void *)text,size);
    uintptr_t text_va = text - (uintptr_t)slide;
    uint8_t uuid[16] = {0x54,0x3c,0x93,0x0a,0x43,0x2c,0x36,0xfb,0x99,0x88,0x42,0x21,0x4b,0xd9,0xd9,0x3c};
    // Mutate a non-entry byte in each complete function, in private heap memory.
    uintptr_t sites[] = {0x66d22f,0x66cd9f,0x66ced3,0x66cacd,0x66cf8c};
    for (size_t i=0;i<sizeof(sites)/sizeof(sites[0]);++i) {
        CHECK(sites[i] >= text_va && sites[i]-text_va < size, "mutation stays in copied bytes");
        size_t offset = sites[i]-text_va;
        copy[offset] ^= 1;
        CHECK(!np_intel_compat_review(uuid,copy,size,text_va,slide,&resolved,&layout), "body mutation rejected");
        CHECK(!memcmp(&layout,&zero,sizeof(zero)), "failed review clears all permissions");
        copy[offset] ^= 1;
    }
    CHECK(np_intel_compat_review(uuid,copy,size,text_va,slide,&resolved,&layout), "unchanged copy accepted");
    CHECK(!np_intel_compat_review(uuid,copy,16,text_va,slide,&resolved,&layout), "truncated section rejected");
    CHECK(!np_intel_compat_review(uuid,copy,size,UINTPTR_MAX-16,slide,&resolved,&layout), "out-of-range section rejected");
    uuid[0] ^= 1;
    CHECK(!np_intel_compat_review(uuid,copy,size,text_va,slide,&resolved,&layout), "wrong UUID rejected");
    uuid[0] ^= 1;
    entries[4].site++;
    CHECK(!np_intel_compat_review(uuid,copy,size,text_va,slide,&resolved,&layout), "wrong resolved instruction rejected");
    entries[4].site--;
    resolved.used--;
    CHECK(!np_intel_compat_review(uuid,copy,size,text_va,slide,&resolved,&layout), "missing required instruction rejected");
    resolved.used++;
    entries[4] = entries[3];
    CHECK(!np_intel_compat_review(uuid,copy,size,text_va,slide,&resolved,&layout), "duplicate instruction rejected");
    struct mach_header_64 wrong = *mh;
    wrong.cputype = CPU_TYPE_ARM64;
    CHECK(!np_intel_compat_from_image(&wrong,slide,&resolved,&layout), "ARM image rejected before reading commands");
    free(copy);
    puts("PASS: Intel complete-function/UUID/layout validation and negative checks; no hooks installed");
    return 0;
}
