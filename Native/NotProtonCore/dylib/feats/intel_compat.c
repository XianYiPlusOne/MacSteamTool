#include "intel_compat.h"
#include "../core/macho.h"
#include <CommonCrypto/CommonDigest.h>
#include <mach/machine.h>
#include <string.h>

// Steam 1794536281, x86_64. Reviewed disassembly and reproduction commands:
// Native/SteamIntegration/INTEL-COMPAT.md. These hashes cover whole functions,
// including the field loads, branch destinations and the two register sites.
static const uint8_t client_uuid[16] = {
    0x54,0x3c,0x93,0x0a,0x43,0x2c,0x36,0xfb,0x99,0x88,0x42,0x21,0x4b,0xd9,0xd9,0x3c
};

static const struct {
    uintptr_t va;
    size_t size;
    const char *sha256;
} reviewed_functions[] = {
    {0x66d1f0, 0x142, "0993e4e8151190598d2c977cf8ecc34d210a01b83fadb334c96c2669db7b8b2a"},
    {0x66cc78, 0x166, "8bd5d08ff8a466084062801d7d72bdd3ad7ab322eea633b6add0d4e61b4f0ad4"},
    {0x66cdde, 0x140, "9ab2ffbc43e634e378272fc79339eca938712404c8eac184b98285a4d6356231"},
    {0x66ca62, 0x1e2, "f9ae904abace423b8aa29a05486300f21086ae02418abf7a9c4a23b6c98d5c5f"},
    {0x66cf7c, 0x118, "d8dc85a1372dcf21697636170ae78edae1907250a6d980b7e8851c64f3f95f27"},
};

static const struct { const char *name; uintptr_t va; } required_sites[] = {
    {"CCompatManager::BIsCompatibilityToolEnabled", 0x66d1f0},
    {"CCompatManager::GetWildcardMapping", 0x66ca62},
    {"CCompatManager::WindowsOnlyLookup", 0x66cf7c},
    {"CCompatManager::GetOSListOverrideForApp.oslist_gate", 0x66cd29},
    {"CCompatManager::ResolveCompatToolForApp.local_redirect", 0x66ce14},
};

static int hash_matches(const uint8_t *bytes, size_t size, const char *expected) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    char actual[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    static const char hex[] = "0123456789abcdef";
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA256(bytes, (CC_LONG)size, digest);
#pragma clang diagnostic pop
    for (size_t i = 0; i < sizeof(digest); ++i) {
        actual[i * 2] = hex[digest[i] >> 4];
        actual[i * 2 + 1] = hex[digest[i] & 15];
    }
    actual[sizeof(actual) - 1] = 0;
    return !strcmp(actual, expected);
}

int np_intel_compat_review(const uint8_t uuid[16], const uint8_t *text,
                           size_t text_size, uintptr_t text_va, intptr_t slide,
                           const np_resolve_result_t *resolved,
                           np_intel_compat_layout_t *out) {
    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!uuid || !text || !resolved || !resolved->items || resolved->used <= 0 ||
        memcmp(uuid, client_uuid, sizeof(client_uuid))) return 0;
    for (size_t i = 0; i < sizeof(reviewed_functions) / sizeof(reviewed_functions[0]); ++i) {
        uintptr_t va = reviewed_functions[i].va;
        size_t size = reviewed_functions[i].size;
        if (va < text_va || size > text_size || va - text_va > text_size - size ||
            !hash_matches(text + (va - text_va), size, reviewed_functions[i].sha256)) return 0;
    }
    for (size_t i = 0; i < sizeof(required_sites) / sizeof(required_sites[0]); ++i) {
        int matches = 0;
        uintptr_t expected = required_sites[i].va + (uintptr_t)slide;
        for (int n = 0; n < resolved->used; ++n) {
            if (!resolved->items[n].name || strcmp(resolved->items[n].name, required_sites[i].name)) continue;
            if (resolved->items[n].site != expected) return 0;
            ++matches;
        }
        if (matches != 1) return 0;
    }
    *out = (np_intel_compat_layout_t){
        .tool_shift = 8, .enabled_offset = 0x810, .windows_only_offset = 0x698,
        .oslist_gate = 0x66cd29 + (uintptr_t)slide,
        .local_redirect = 0x66ce14 + (uintptr_t)slide,
    };
    return 1;
}

int np_intel_compat_from_image(const struct mach_header_64 *mh, intptr_t slide,
                               const np_resolve_result_t *resolved,
                               np_intel_compat_layout_t *out) {
    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!mh || mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_X86_64 ||
        mh->sizeofcmds > 1024 * 1024 || mh->ncmds > mh->sizeofcmds / sizeof(struct load_command)) return 0;
    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    size_t remaining = mh->sizeofcmds;
    const uint8_t *uuid = NULL;
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        if (remaining < sizeof(struct load_command)) return 0;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > remaining) return 0;
        if (command->cmd == LC_UUID) {
            if (uuid || command->cmdsize < sizeof(struct uuid_command)) return 0;
            uuid = ((const struct uuid_command *)command)->uuid;
        }
        remaining -= command->cmdsize;
        cursor += command->cmdsize;
    }
    if (!uuid || memcmp(uuid, client_uuid, sizeof(client_uuid))) return 0;
    uintptr_t text = 0;
    size_t size = 0;
    if (np_find_section(mh, slide, "__TEXT", "__text", &text, &size)) return 0;
    // Also require actual function boundaries, not just bytes at a guessed site.
    for (size_t i = 0; i < sizeof(reviewed_functions) / sizeof(reviewed_functions[0]); ++i) {
        uintptr_t start = 0, end = 0, expected = reviewed_functions[i].va + (uintptr_t)slide;
        if (np_function_bounds(mh, slide, expected, &start, &end) || start != expected ||
            end < start || end - start != reviewed_functions[i].size) return 0;
    }
    return np_intel_compat_review(uuid, (const void *)text, size, text - (uintptr_t)slide, slide, resolved, out);
}

int np_intel_compat_allows(const np_intel_compat_layout_t *layout,
                           const char *signature, uintptr_t address) {
    if (!layout || !signature || !address) return 0;
    return (!strcmp(signature, "CCompatManager::GetOSListOverrideForApp.oslist_gate") &&
            layout->oslist_gate == address) ||
           (!strcmp(signature, "CCompatManager::ResolveCompatToolForApp.local_redirect") &&
            layout->local_redirect == address);
}
