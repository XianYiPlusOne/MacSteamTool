// Signature resolver

#include "resolver.h"
#include "anchor.h"
#include "aob.h"
#include "../core/arch.h"
#include "../core/macho.h"
#include "../util/log.h"

#include <CommonCrypto/CommonDigest.h>
#include <stdlib.h>
#include <string.h>

// Prologue detection
#if !defined(__x86_64__)
static const struct { uint32_t mask, val; } prologue_forms[] = {
    { 0xFF0003FF, 0xD10003FF },  // SUB  SP, SP, #imm
    { 0xFFC07FFF, 0xA9007BFD },  // STP  x29, x30, [SP, #off]
    { 0xFFC07FFF, 0xA9807BFD },  // STP  x29, x30, [SP, #off]!
    { 0xFFFFFFFF, 0xD503237F },  // PACIBSP  (sign LR)
    { 0xFFFFFFFF, 0x910003FD },  // MOV  x29, SP
    { 0xFFC003E0, 0xA98003E0 },  // STP  Xt, Xt2, [SP, #off]!
    { 0xFFC003E0, 0xA90003E0 },  // STP  Xt, Xt2, [SP, #off]
};
#endif

int np_looks_like_prologue(uintptr_t addr) {
    if (!addr) return 0;
#if defined(__x86_64__)
    const uint8_t *p = (const uint8_t *)addr;
    if (p[0] == 0x55 && p[1] == 0x48 && p[2] == 0x89 && p[3] == 0xE5) return 1;
    if (p[0] == 0x48 && p[1] == 0x83 && p[2] == 0xEC) return 1;
    if (p[0] == 0x48 && p[1] == 0x81 && p[2] == 0xEC) return 1;
    if (p[0] == 0x41 && (p[1] & 0xF8) == 0x50) return 1;
    return p[0] == 0x53 || p[0] == 0x56 || p[0] == 0x57;
#else
    uint32_t w = *(const uint32_t *)addr;
    for (int i = 0; i < (int)(sizeof(prologue_forms) / sizeof(prologue_forms[0])); i++) {
        if ((w & prologue_forms[i].mask) == prologue_forms[i].val)
            return 1;
    }
    return 0;
#endif
}

// Result accumulator
static void push(np_resolve_result_t *r, const char *name, uintptr_t addr) {
    if (r->used == r->cap) {
        int grown = r->cap ? r->cap * 2 : 32;
        np_resolved_t *buf = realloc(r->items, (size_t)grown * sizeof(*buf));
        if (!buf) return;
        r->items = buf;
        r->cap   = grown;
    }
    r->items[r->used++] = (np_resolved_t){ .name = name, .site = addr };
}

static int usable_code_address(const char *name, uintptr_t addr,
                               uintptr_t text, size_t text_sz);

// Single-signature resolution
uintptr_t np_aob_site(const np_sig_entry_t *sig, uintptr_t text, size_t text_sz) {
    if (!sig || !sig->aob_hex[0]) return 0;
    if (text_sz < sizeof(uint32_t)) return 0;

    np_byte_pattern_t pat;
    if (np_compile_pattern(sig->aob_hex, &pat) != 0) {
        NP_WARN("resolver: '%s' has an unparseable byte pattern", sig->name);
        return 0;
    }

    uintptr_t hit = np_scan_sole_match(text, text_sz, &pat);
    np_release_pattern(&pat);
    if (!hit) return 0;

    uintptr_t site = hit - (uintptr_t)(intptr_t)sig->match_offset;
    if (!usable_code_address(sig->name, site, text, text_sz))
        return 0;
    return site;
}

static int anchor_targets_function_entry(np_match_kind_t kind) {
    switch (kind) {
        case NP_MATCH_STRING:
        case NP_MATCH_VTABLE_SLOT:
        case NP_MATCH_CALL_TARGET:
        case NP_MATCH_CALLS:
        case NP_MATCH_RTTI_SLOT:
            return 1;
        case NP_MATCH_NONE:
        case NP_MATCH_INSN_AFTER_STRING:
        case NP_MATCH_INSN_PAIR_IN_FN:
        case NP_MATCH_AOB:
            return 0;
    }
    return 0;
}

static int aob_site_plausible(const np_sig_entry_t *sig,
                             const struct mach_header_64 *mh, intptr_t slide,
                             uintptr_t addr) {
    uintptr_t start = 0, end = 0;
    int bounded = np_function_bounds(mh, slide, addr, &start, &end) == 0;

    if (!anchor_targets_function_entry(sig->anchor.kind)) {
        if (!bounded)
            NP_WARN("resolver: '%s' byte pattern site 0x%lx is not inside any known "
                    "function; rejecting", sig->name, (unsigned long)addr);
        return bounded;
    }

    if (bounded) {
        if (start != addr) {
            NP_WARN("resolver: '%s' byte pattern hit 0x%lx is inside 0x%lx, not a "
                    "function start; rejecting", sig->name, (unsigned long)addr,
                    (unsigned long)start);
            return 0;
        }
        return 1;
    }
    if (!np_looks_like_prologue(addr)) {
        NP_WARN("resolver: '%s' byte pattern hit 0x%lx has no function bounds and "
                "does not open with a prologue; rejecting", sig->name,
                (unsigned long)addr);
        return 0;
    }
    return 1;
}

static uintptr_t try_anchor(np_sig_entry_t *sig,
                            const struct mach_header_64 *mh, intptr_t slide,
                            uintptr_t text, size_t text_sz) {
    if (sig->anchor.kind == NP_MATCH_AOB) {
        uintptr_t addr = np_aob_site(sig, text, text_sz);
        if (!addr) return 0;
        if (!aob_site_plausible(sig, mh, slide, addr)) return 0;
        NP_LOG("resolver: '%s' -> 0x%lx [aob]", sig->name, (unsigned long)addr);
        return addr;
    }

    uintptr_t addr = 0;
    if (sig->anchor.kind != NP_MATCH_NONE)
        addr = np_locate_anchor(mh, slide, text, text_sz, &sig->anchor);

    uintptr_t alt = np_aob_site(sig, text, text_sz);

    if (!addr) {
        if (!alt) return 0;
        if (!aob_site_plausible(sig, mh, slide, alt)) return 0;

        NP_LOG("resolver: '%s' -> 0x%lx [aob, anchor did not resolve]",
               sig->name, (unsigned long)alt);
        return alt;
    }

    if (alt && alt != addr)
        NP_WARN("resolver: '%s' anchor 0x%lx disagrees with byte pattern 0x%lx; "
                "keeping the anchor", sig->name, (unsigned long)addr,
                (unsigned long)alt);

    NP_LOG("resolver: '%s' -> 0x%lx [anchor]", sig->name, (unsigned long)addr);
    return addr;
}

static int usable_code_address(const char *name, uintptr_t addr,
                               uintptr_t text, size_t text_sz) {
    if (NP_SCAN_ALIGNMENT > 1u && (addr % NP_SCAN_ALIGNMENT) != 0) {
        NP_WARN("resolver: '%s' resolved to 0x%lx, not an aligned instruction "
                "address; rejecting", name, (unsigned long)addr);
        return 0;
    }
    if (addr < text || addr > text + text_sz - sizeof(uint32_t)) {
        NP_WARN("resolver: '%s' resolved to 0x%lx, outside __TEXT "
                "0x%lx..0x%lx; rejecting", name, (unsigned long)addr,
                (unsigned long)text, (unsigned long)(text + text_sz));
        return 0;
    }
    return 1;
}

// Intel profiles use exact, reviewed functions. Never reinterpret x86 bytes as
// ARM anchors or rescue a rejected function by scanning elsewhere in the image.
static int exact_image(const struct mach_header_64 *mh, const np_sigdb_t *db) {
    if (mh->magic != MH_MAGIC_64 || mh->cputype != NP_CPU_TYPE ||
        strcmp(db->arch, NP_ARCH_NAME) || db->schema_version != 4 ||
        strlen(db->module_uuid) != 32 || mh->sizeofcmds > 1024 * 1024) return 0;
    const unsigned char *p = (const unsigned char *)(mh + 1);
    size_t left = mh->sizeofcmds;
    int matched = 0;
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        if (left < sizeof(struct load_command)) return 0;
        const struct load_command *lc = (const void *)p;
        if (lc->cmdsize < sizeof(*lc) || lc->cmdsize > left) return 0;
        if (lc->cmd == LC_UUID) {
            if (lc->cmdsize != sizeof(struct uuid_command) || matched) return 0;
            const struct uuid_command *u = (const void *)p;
            char hex[33];
            for (int n = 0; n < 16; ++n) snprintf(hex + n*2, 3, "%02x", u->uuid[n]);
            if (strcmp(hex, db->module_uuid)) return 0;
            matched = 1;
        }
        left -= lc->cmdsize; p += lc->cmdsize;
    }
    return matched;
}

static uintptr_t exact_site(const struct mach_header_64 *mh, intptr_t slide,
                             const np_sig_entry_t *sig, uintptr_t text, size_t size) {
    if (!sig->function_start || !sig->function_size ||
        sig->function_size > UINT32_MAX || strlen(sig->function_sha256) != 64 ||
        sig->func_addr_this_build < sig->function_start ||
        sig->func_addr_this_build - sig->function_start >= sig->function_size) return 0;
    uintptr_t start = sig->function_start + (uintptr_t)slide;
    if (start < text || sig->function_size > size || start - text > size - sig->function_size) return 0;
    uintptr_t actual_start = 0, actual_end = 0;
    if (np_function_bounds(mh, slide, start, &actual_start, &actual_end) ||
        actual_start != start || actual_end - start != sig->function_size) return 0;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    char hex[65];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA256((const void *)start, (CC_LONG)sig->function_size, digest);
#pragma clang diagnostic pop
    for (int n = 0; n < CC_SHA256_DIGEST_LENGTH; ++n) snprintf(hex + n*2, 3, "%02x", digest[n]);
    return strcmp(hex, sig->function_sha256) ? 0 : sig->func_addr_this_build + (uintptr_t)slide;
}

// Public API
int np_required_for_module(const np_sigdb_t *sigdb, const char *module) {
    if (!sigdb || !module) return 0;
    int n = 0;
    for (int i = 0; i < sigdb->sig_count; i++) {
        const np_sig_entry_t *sig = &sigdb->signatures[i];
        if (!sig->deprecated && !sig->optional && strcmp(sig->module, module) == 0)
            n++;
    }
    return n;
}

int np_module_has_signatures(const np_sigdb_t *sigdb, const char *module) {
    if (!sigdb || !module) return 0;
    for (int i = 0; i < sigdb->sig_count; i++) {
        const np_sig_entry_t *sig = &sigdb->signatures[i];
        if (!sig->deprecated && strcmp(sig->module, module) == 0)
            return 1;
    }
    return 0;
}

int np_resolve_signatures(const struct mach_header_64 *mh, intptr_t slide,
                      np_sigdb_t *sigdb, const char *module,
                      np_resolve_result_t *out) {
    if (!mh || !sigdb || !module || !out) return 0;
    memset(out, 0, sizeof(*out));

    if (mh->cputype != NP_CPU_TYPE || (sigdb->arch[0] && strcmp(sigdb->arch, NP_ARCH_NAME))) return 0;
    int exact = sigdb->schema_version == 4;
#if defined(__x86_64__)
    if (!exact) return 0;
#endif
    if (exact && !exact_image(mh, sigdb)) return 0;
    uintptr_t text;
    size_t text_sz;
    if (np_find_segment(mh, slide, "__TEXT", &text, &text_sz) != 0) {
        NP_ERR("resolver: __TEXT segment not found in %s, cannot scan", module);
        return 0;
    }

    NP_LOG("resolver: scanning %s __TEXT @ 0x%lx (%zu bytes)", module, text, text_sz);

    int resolved = 0;
    int optional = 0, optional_resolved = 0;

    for (int i = 0; i < sigdb->sig_count; i++) {
        np_sig_entry_t *sig = &sigdb->signatures[i];

        if (strcmp(sig->module, module) != 0)
            continue;

        if (sig->deprecated) {
            push(out, sig->name, 0);
            continue;
        }

        uintptr_t addr = exact ? exact_site(mh, slide, sig, text, text_sz)
                               : try_anchor(sig, mh, slide, text, text_sz);

        if (addr && !usable_code_address(sig->name, addr, text, text_sz))
            addr = 0;

        if (sig->optional) {
            optional++;
            if (addr)
                optional_resolved++;
            else
                NP_WARN("resolver: optional '%s' did not resolve, its hooks stay off",
                        sig->name);
        } else if (addr) {
            resolved++;
        }

        push(out, sig->name, addr);
    }

    NP_LOG("resolver: %s %d/%d signatures resolved, %d/%d optional", module, resolved,
           np_required_for_module(sigdb, module), optional_resolved, optional);
    return resolved;
}

uintptr_t np_lookup_address(const np_resolve_result_t *result, const char *name) {
    if (!result || !name) return 0;
    for (int i = 0; i < result->used; i++) {
        if (result->items[i].name && strcmp(result->items[i].name, name) == 0)
            return result->items[i].site;
    }
    return 0;
}

void np_free_resolution(np_resolve_result_t *result) {
    if (!result) return;
    free(result->items);
    memset(result, 0, sizeof(*result));
}
