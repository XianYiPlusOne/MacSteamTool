cmake_minimum_required(VERSION 3.20)
project(MacSteamToolIntegration LANGUAGES C CXX)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0)
set(CMAKE_C_STANDARD 17)
if(NOT DOBBY_LIBRARY)
  message(FATAL_ERROR "Build with script/build_native_integration.py")
endif()
set(MAC_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/../MacSteam")
set(NP_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/../NotProtonCore")
file(GLOB_RECURSE MAC_SOURCES CONFIGURE_DEPENDS "${MAC_SOURCE}/src/*.c")
list(FILTER MAC_SOURCES EXCLUDE REGEX "stub_x86_64.c$")
file(GLOB_RECURSE NP_SOURCES CONFIGURE_DEPENDS "${NP_SOURCE}/dylib/*.c")
list(FILTER NP_SOURCES EXCLUDE REGEX "/tests/|stub_x86_64.c$")
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/generated/compat_run.h"
  COMMAND python3 "${NP_SOURCE}/dylib/embed_script.py"
    "${NP_SOURCE}/dylib/feats/compat_run.sh" "${CMAKE_CURRENT_BINARY_DIR}/generated/compat_run.h" RUN_SCRIPT
  DEPENDS "${NP_SOURCE}/dylib/feats/compat_run.sh" "${NP_SOURCE}/dylib/feats/compat-defaults.sh"
    "${NP_SOURCE}/dylib/feats/compat-prefix.sh" "${NP_SOURCE}/dylib/embed_script.py")
# The Intel bootstrap uses a stub; the ARM64 client needs the complete runtime.
add_library(macsteam SHARED ${MAC_SOURCES} "${MAC_SOURCE}/vendor/cJSON.c")
add_library(notproton SHARED ${NP_SOURCES} "${NP_SOURCE}/vendor/cJSON.c"
  "${CMAKE_CURRENT_BINARY_DIR}/generated/compat_run.h")
target_include_directories(macsteam PRIVATE "${MAC_SOURCE}/src" "${MAC_SOURCE}/vendor")
target_include_directories(notproton PRIVATE "${NP_SOURCE}/dylib" "${NP_SOURCE}/vendor" "${CMAKE_CURRENT_BINARY_DIR}/generated")
foreach(target macsteam notproton)
  set_target_properties(${target} PROPERTIES PREFIX "" INSTALL_NAME_DIR "@rpath")
  target_compile_options(${target} PRIVATE -O2 -Wall -Wextra -Wno-unused-parameter)
endforeach()
target_link_libraries(macsteam PRIVATE "${DOBBY_LIBRARY}" c++ "-framework CoreFoundation" "-framework CFNetwork")
target_link_libraries(notproton PRIVATE "${DOBBY_LIBRARY}" c++ "-framework CoreFoundation")
target_link_libraries(notproton PRIVATE "-framework CoreGraphics")
