#if defined(__x86_64__)
/*
 * Swift emits this data symbol as a force-load request for the Swift 5.6
 * compatibility archive.  The macOS 27 Command Line Tools contain that
 * archive only for arm64, while this project targets macOS 14 where the
 * current runtime already supplies every compatibility entry point used by
 * our dependencies.  Supplying the request symbol is therefore sufficient
 * and avoids pretending that an arm64 archive can satisfy an x86_64 link.
 */
__attribute__((visibility("default")))
void *swiftCompatibility56ForceLoad
    __asm__("__swift_FORCE_LOAD_$_swiftCompatibility56");
void *swiftCompatibility56ForceLoad;

void swiftCompatibilityShimAnchor(void) {}
#endif
