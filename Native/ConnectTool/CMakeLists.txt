cmake_minimum_required(VERSION 3.28)
project(FluentConnect LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_SCAN_FOR_MODULES OFF)
set(CMAKE_AUTOMOC ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
if(CMAKE_CXX_COMPILER_ID STREQUAL "AppleClang")
  add_compile_options(-fexperimental-library)
  add_link_options(-fexperimental-library)
endif()
find_package(Qt6 6.11.1 REQUIRED COMPONENTS Core Gui Network Test)
find_package(Threads REQUIRED)
set(U "${CMAKE_CURRENT_SOURCE_DIR}/upstream")
file(GLOB_RECURSE CORE CONFIGURE_DEPENDS "${U}/src/network/*.cpp" "${U}/src/integrations/steam/*.cpp")
file(GLOB MODELS CONFIGURE_DEPENDS "${U}/modules/ConnectTool/models/*.cpp" "${U}/modules/ConnectTool/models/*.h")
add_library(connect_core STATIC ${CORE} ${MODELS}
  "${U}/src/application/runtime/application_runtime.cpp"
  "${U}/src/application/runtime/application_runtime.h"
  "${U}/src/application/services/update_controller.cpp"
  "${U}/src/application/services/update_controller.h"
  "${U}/src/platform/audio/sound_notifier.cpp"
  "${U}/src/platform/system/platform_environment.cpp"
  "${U}/src/platform/tun/tun_macos.cpp"
  "${U}/src/platform/tun/tun_privileged_helper.cpp")
target_include_directories(connect_core PUBLIC "${U}/src" "${U}/modules" "${STEAM_HEADERS}" "${BOOST_HEADERS}" "${U}/deps/vendor/cute_sound")
target_compile_definitions(connect_core PUBLIC CONNECTTOOL_VERSION="1.6.0")
target_link_libraries(connect_core PUBLIC Qt6::Core Qt6::Gui Qt6::Network Threads::Threads "${STEAM_LIBRARY}" "-framework CoreAudio" "-framework AudioUnit" "-framework AudioToolbox")
add_executable(FluentConnect Bridge.cpp)
target_link_libraries(FluentConnect PRIVATE connect_core)
set_target_properties(FluentConnect PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "@loader_path/../Frameworks")
add_executable(connecttool-tun-daemon "${U}/src/platform/tun/tun_macos_daemon.cpp" "${U}/src/platform/tun/tun_privileged_helper.cpp")
target_include_directories(connecttool-tun-daemon PRIVATE "${U}/src")
# The system helper uses no Steam/Qt libraries and runs natively on either Mac.
set_target_properties(connecttool-tun-daemon PROPERTIES OSX_ARCHITECTURES "arm64;x86_64")
add_executable(connecttool_protocol_tests "${U}/tests/protocol_tests.cpp")
target_link_libraries(connecttool_protocol_tests PRIVATE connect_core Qt6::Test)
enable_testing()
add_test(NAME protocol COMMAND connecttool_protocol_tests)
