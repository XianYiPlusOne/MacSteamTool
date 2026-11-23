#ifndef NOTPROTON_UTIL_CXX_STRING_H
#define NOTPROTON_UTIL_CXX_STRING_H
#include <stdint.h>

// Steam's protobuf ArenaStringPtr contains a tagged pointer to libc++ string.
// Intel uses the ordinary libc++ layout; ARM uses its alternate layout.
static inline const char *np_steam_string_field(uintptr_t field) {
    uintptr_t str = *(const uintptr_t *)field & ~(uintptr_t)1;
    if (!str) return "";
#if defined(__x86_64__)
    const uint8_t *bytes = (const uint8_t *)str;
    return bytes[0] & 1 ? *(const char *const *)(str + 16) : (const char *)(str + 1);
#else
    const int8_t *bytes = (const int8_t *)str;
    return bytes[23] < 0 ? *(const char *const *)str : (const char *)str;
#endif
}
#endif
