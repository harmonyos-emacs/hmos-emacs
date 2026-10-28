cmake_minimum_required(VERSION 3.5.0)
project(emacs_hmos)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
# OHOS GUI ABI shared with the Emacs submodule (ohos_host_abi.h).
set(OHOS_EMACS_SRC ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../emacs/src)

include_directories(${NATIVERENDER_ROOT_PATH} ${OHOS_EMACS_SRC}
  ${CMAKE_CURRENT_SOURCE_DIR}/common
  ${CMAKE_CURRENT_SOURCE_DIR}/gui
  ${CMAKE_CURRENT_SOURCE_DIR}/host
)


add_library(entry SHARED
  host/napi_module.cpp host/emacs_host.cpp host/runtime_install.cpp
  host/ime.cpp host/system_bridge.cpp host/host_context.cpp host/napi/api_emacs.cpp host/napi/api_system.cpp host/napi/api_runtime.cpp
  common/text_lines.cpp common/napi_util.cpp
  gui/api.cpp gui/ohos_gui.cpp
  gui/input.cpp gui/surface_host.cpp)

target_compile_features(entry PRIVATE cxx_std_17)
target_compile_options(entry PRIVATE -O2 -Wall -Wextra -Wno-unused-parameter)
target_link_options(entry PRIVATE
  "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/libentry.map"
  "-Wl,--exclude-libs,ALL")

target_link_libraries(entry PUBLIC
  libace_napi.z.so
  libace_ndk.z.so
  libhilog_ndk.z.so
  libnative_window.so
  libohinputmethod.so
  z)
