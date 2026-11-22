#pragma once

#include <mach/machine.h>

/* Every native component is compiled once per slice. */
#if defined(__x86_64__)
#define FLUENT_ARCH_NAME "x86_64"
#define FLUENT_CPU_TYPE CPU_TYPE_X86_64
#elif defined(__arm64__) || defined(__aarch64__)
#define FLUENT_ARCH_NAME "arm64"
#define FLUENT_CPU_TYPE CPU_TYPE_ARM64
#else
#error "Fluent native components support only arm64 and x86_64 macOS"
#endif
