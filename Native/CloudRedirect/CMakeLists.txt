cmake_minimum_required(VERSION 3.20)
project(FluentCloudRedirect LANGUAGES C CXX OBJCXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
set(CMAKE_OSX_ARCHITECTURES arm64)
if(NOT DEFINED DOBBY_SOURCE)
  message(FATAL_ERROR "Use script/build_cloud.sh")
endif()
set(DOBBY_DEBUG OFF CACHE BOOL "" FORCE)
set(Plugin.SymbolResolver ON CACHE BOOL "" FORCE)
add_subdirectory("${DOBBY_SOURCE}" dobby EXCLUDE_FROM_ALL)
include("${CMAKE_CURRENT_SOURCE_DIR}/../Common/dobby_patch.cmake")
add_library(cloud_redirect SHARED

    common/protobuf.cpp
    common/json.cpp
    common/coop_yield.cpp
    common/vdf.cpp
    common/remotecache_repair.cpp
    common/manifest_store.cpp
    common/app_state.cpp
    common/token_store.cpp
    common/batch_tracker.cpp
    common/cloud_staging.cpp
    common/pending_ops_journal.cpp
    common/rpc_handlers.cpp
    common/batch_merge.cpp
    common/cloud_work_queue.cpp
    common/cloud_storage.cpp
    common/local_storage.cpp
    common/local_metadata_store.cpp
    common/legacy_metadata_cleanup.cpp
    common/cli.cpp
    common/cloud_provider_base.cpp
    common/sigv4.cpp
    common/sha256_hmac.cpp
    common/autocloud_scan.cpp
    common/steam_kv_injector.cpp
    common/parental_bypass.cpp
    common/metadata_sync.cpp
    common/stats_store.cpp
    common/stats_journal.cpp
    common/stats_handlers.cpp
    common/miniz.c
    common/miniz_tdef.c
    common/miniz_tinfl.c
    common/miniz_zip.c
    providers/google_drive.cpp
    providers/onedrive.cpp
    providers/local_disk_provider.cpp
    providers/s3_provider.cpp
    providers/r2_provider.cpp
    providers/webdav_provider.cpp
macos/init.cpp
macos/steam_profile.cpp
macos/vtable_hook.cpp
macos/cloud_hooks.cpp
macos/cloud_intercept.cpp
macos/stats_hooks.cpp
macos/gamesplayed_hook.cpp
macos/live_playtime.cpp
macos/runtime_settings.cpp
macos/ticket_hooks.cpp
macos/ownership_hooks.cpp
macos/onlinefix.cpp
macos/manifest_provider.cpp
macos/manifest_json.mm
macos/access_tokens.cpp
macos/presence_apps.cpp
macos/save_inventory.cpp
macos/presence_shortcuts.cpp
macos/http_transport_linux.cpp
macos/token_store_linux.cpp
macos/log.cpp
macos/http_server.cpp
macos/http_util.cpp
macos/platform_linux.cpp
macos/file_util.cpp)
set_target_properties(cloud_redirect PROPERTIES PREFIX "" INSTALL_NAME_DIR "@loader_path")
target_include_directories(cloud_redirect PRIVATE common providers macos "${DOBBY_SOURCE}/include")
target_compile_definitions(cloud_redirect PRIVATE MINIZ_NO_STDIO CR_VERSION_STRING="mac-port-0.1" CR_RELEASE_VERSION="mac-port-0.1")
target_compile_options(cloud_redirect PRIVATE -Wno-deprecated-declarations)
add_executable(FluentCloudCLI macos/cli_main.cpp)
add_executable(FluentCloudProbe tests/native_probe.cpp)
target_include_directories(FluentCloudProbe PRIVATE common providers macos)
target_link_libraries(FluentCloudProbe PRIVATE cloud_redirect)

target_link_libraries(cloud_redirect PRIVATE dobby_static curl "-framework Foundation")
target_link_options(cloud_redirect PRIVATE "-Wl,-unexported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/macos/hidden_symbols.txt")
add_executable(FluentRuntimeProbe tests/runtime_probe.cpp)
add_executable(FluentOnlineFixProbe tests/onlinefix_probe.cpp)
target_include_directories(FluentOnlineFixProbe PRIVATE common providers macos "${DOBBY_SOURCE}/include")
target_link_libraries(FluentOnlineFixProbe PRIVATE cloud_redirect dobby_static)
target_include_directories(FluentRuntimeProbe PRIVATE common providers macos)
target_link_libraries(FluentRuntimeProbe PRIVATE cloud_redirect dobby_static)
add_executable(FluentProviderProbe tests/provider_probe.cpp)
target_include_directories(FluentProviderProbe PRIVATE common providers macos)
target_link_libraries(FluentProviderProbe PRIVATE cloud_redirect)

add_executable(FluentCloudOnlineProbe tests/cloud_online_probe.cpp)
add_executable(FluentStatsConcurrencyProbe tests/stats_concurrency_probe.cpp)
target_include_directories(FluentStatsConcurrencyProbe PRIVATE common providers macos)
target_link_libraries(FluentStatsConcurrencyProbe PRIVATE cloud_redirect)
target_include_directories(FluentCloudOnlineProbe PRIVATE common providers macos)
target_link_libraries(FluentCloudOnlineProbe PRIVATE cloud_redirect)
add_executable(FluentAchievementProbe tests/achievement_probe.cpp)
target_include_directories(FluentAchievementProbe PRIVATE common providers macos)
target_link_libraries(FluentAchievementProbe PRIVATE cloud_redirect)
