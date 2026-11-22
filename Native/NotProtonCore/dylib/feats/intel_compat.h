#ifndef NOTPROTON_INTEL_COMPAT_H
#define NOTPROTON_INTEL_COMPAT_H

#include "../resolver/resolver.h"

typedef struct {
    int32_t tool_shift;
    uint32_t enabled_offset;
    uint32_t windows_only_offset;
    uintptr_t oslist_gate;
    uintptr_t local_redirect;
} np_intel_compat_layout_t;

// Read-only validation of a reviewed Intel code view. No wildcard scanning or
// baseline fallback: every function supplying a field/register must still match.
int np_intel_compat_review(const uint8_t uuid[16], const uint8_t *text,
                           size_t text_size, uintptr_t text_va, intptr_t slide,
                           const np_resolve_result_t *resolved,
                           np_intel_compat_layout_t *out);
int np_intel_compat_from_image(const struct mach_header_64 *mh, intptr_t slide,
                               const np_resolve_result_t *resolved,
                               np_intel_compat_layout_t *out);
int np_intel_compat_allows(const np_intel_compat_layout_t *layout,
                           const char *signature, uintptr_t address);

#endif
