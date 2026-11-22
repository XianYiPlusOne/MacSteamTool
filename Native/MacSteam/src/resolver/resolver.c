// Signature resolver
#include "resolver.h"
#include "../core/arch.h"
#include "aob.h"
#include "anchor.h"
#include "../core/macho.h"
#include "../util/log.h"

#include <stdlib.h>
#include <string.h>

int sx_is_arm64_prologue(uintptr_t addr) {
    if (!addr) return 0;
    uint32_t insn = *(const uint32_t *)addr;

    if ((insn & 0xFF0003FF) == 0xD10003FF) return 1; // SUB SP, SP, #imm
    if ((insn & 0xFFC07FFF) == 0xA9007BFD) return 1; // STP x29, x30, [SP, #off]
    if ((insn & 0xFFC07FFF) == 0xA9807BFD) return 1; // STP x29, x30, [SP, #off]!
    if (insn == 0xD503237F) return 1;                 // PACIBSP
    if (insn == 0x910003FD) return 1;                 // MOV x29, SP
    if ((insn & 0xFFC003E0) == 0xA98003E0) return 1; // STP Xt, Xt2, [SP, #off]!
    if ((insn & 0xFFC003E0) == 0xA90003E0) return 1; // STP Xt, Xt2, [SP, #off]

    return 0;
}

#if defined(__x86_64__)
static int sx_is_x86_64_prologue(uintptr_t addr) {
    if (!addr) return 0;
    const uint8_t *p = (const uint8_t *)addr;
    /* Clang often omits rbp in Steam's optimised builds. */
    if (p[0] == 0x55 && p[1] == 0x48 && p[2] == 0x89 && p[3] == 0xE5) return 1;
    if (p[0] == 0x48 && p[1] == 0x83 && p[2] == 0xEC) return 1;
    if (p[0] == 0x48 && p[1] == 0x81 && p[2] == 0xEC) return 1;
    if (p[0] == 0x41 && (p[1] & 0xF8) == 0x50) return 1;
    return p[0] == 0x53 || p[0] == 0x56 || p[0] == 0x57;
}
#endif

int sx_is_function_prologue(uintptr_t addr) {
#if defined(__x86_64__)
    return sx_is_x86_64_prologue(addr);
#else
    return sx_is_arm64_prologue(addr);
#endif
}

static void result_add(sx_resolve_result_t *r, const char *name, uintptr_t addr) {
    if (r->count >= r->capacity) {
        int new_cap = r->capacity ? r->capacity * 2 : 64;
        sx_resolved_t *new_entries = (sx_resolved_t *)realloc(
            r->entries, (size_t)new_cap * sizeof(sx_resolved_t));
        if (!new_entries) return;
        r->entries = new_entries;
        r->capacity = new_cap;
    }
    sx_resolved_t *e = &r->entries[r->count++];
    e->name = name;
    e->address = addr;
}

int sx_resolve_all_ex(const struct mach_header_64 *mh, intptr_t slide,
                      const char *dylib_path,
                      sx_sigdb_t *sigdb, sx_resolve_result_t *out) {
    if (!mh || !sigdb || !out) return 0;
    memset(out, 0, sizeof(*out));

    uintptr_t text_base = 0;
    size_t text_size = 0;
    int have_text = (sx_get_segment(mh, slide, "__TEXT", &text_base, &text_size) == 0);

    if (!have_text) {
        SX_ERR("resolver: __TEXT segment not found, cannot scan");
        return 0;
    }

    // A string or a common prologue is not proof of ABI compatibility. Profiles
    // must identify this image and every target must still contain reviewed code.
    if (!sx_sigdb_matches_image(sigdb, mh)) {
        SX_ERR("resolver: unsupported Steam UUID; no hooks installed");
        return 0;
    }
    int resolved = 0;
    for (int i = 0; i < sigdb->sig_count; i++) {
        sx_sig_entry_t *sig = &sigdb->signatures[i];
        uintptr_t addr = 0;
        if (sig->deprecated) { result_add(out, sig->name, 0); continue; }
        sx_pattern_t pat = {0};
        if (sig->reference_va && sig->entry_hex[0] &&
            sx_pattern_from_hex(sig->entry_hex, &pat) == 0) {
            uintptr_t candidate = sig->reference_va + (uintptr_t)slide;
            int valid = pat.length >= 4 && candidate >= text_base &&
                (size_t)pat.length <= text_size && candidate <= text_base + text_size - pat.length;
            for (int n = 0; valid && n < pat.length; ++n)
                valid = pat.mask[n] == 0xff && ((const uint8_t *)candidate)[n] == pat.bytes[n];
            if (valid) addr = candidate;
            sx_pattern_free(&pat);
        }
        // Anchors and wildcard patterns are analysis evidence only. Falling
        // back after an exact entry fails defeats the UUID-scoped ABI review,
        // particularly when porting profiles between instruction sets.
        if (!addr) SX_ERR("resolver: '%s' entry guard rejected", sig->name);
        if (addr) {
            resolved++;
            SX_DBG("resolver: '%s' -> 0x%lx [uuid+entry]", sig->name, addr);
        }

        result_add(out, sig->name, addr);
    }

    SX_LOG("resolver: %d/%d signatures resolved", resolved, sigdb->sig_count);
    return resolved;
}

uintptr_t sx_resolve_find(const sx_resolve_result_t *result, const char *name) {
    if (!result || !name) return 0;
    for (int i = 0; i < result->count; i++) {
        const sx_resolved_t *entry = &result->entries[i];
        if (entry->name && strcmp(entry->name, name) == 0)
            return entry->address;
    }
    return 0;
}

void sx_resolve_result_free(sx_resolve_result_t *result) {
    if (!result) return;
    free(result->entries);
    memset(result, 0, sizeof(*result));
}
