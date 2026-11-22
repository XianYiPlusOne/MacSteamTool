#ifndef MACSTEAM_CORE_ARCH_H
#define MACSTEAM_CORE_ARCH_H

#include <mach/machine.h>

/* This source is compiled once per slice of the universal dylib. */
#if defined(__x86_64__)
#define SX_ARCH_NAME "x86_64"
#define SX_SIGNATURE_DIR "signatures/macos.x86_64"
#define SX_CPU_TYPE CPU_TYPE_X86_64
#define SX_SCAN_ALIGNMENT 1u
#elif defined(__arm64__) || defined(__aarch64__)
#define SX_ARCH_NAME "arm64"
#define SX_SIGNATURE_DIR "signatures/macos.arm64"
#define SX_CPU_TYPE CPU_TYPE_ARM64
#define SX_SCAN_ALIGNMENT 4u
#else
#error "MacSteam supports only arm64 and x86_64 macOS builds"
#endif

#endif
