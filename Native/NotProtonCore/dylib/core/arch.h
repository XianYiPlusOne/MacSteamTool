#ifndef NOTPROTON_CORE_ARCH_H
#define NOTPROTON_CORE_ARCH_H

#include <mach/machine.h>

#if defined(__x86_64__)
#define NP_ARCH_NAME "x86_64"
#define NP_SIGNATURE_DIR "signatures/macos.x86_64"
#define NP_CPU_TYPE CPU_TYPE_X86_64
#define NP_SCAN_ALIGNMENT 1u
#elif defined(__arm64__) || defined(__aarch64__)
#define NP_ARCH_NAME "arm64"
#define NP_SIGNATURE_DIR "signatures/macos.arm64"
#define NP_CPU_TYPE CPU_TYPE_ARM64
#define NP_SCAN_ALIGNMENT 4u
#else
#error "NotProton supports only arm64 and x86_64 macOS builds"
#endif

#endif
