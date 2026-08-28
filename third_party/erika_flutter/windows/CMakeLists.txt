# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. Do not increase this version.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "erika_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "erika_flutter_plugin")

get_filename_component(ERIKA_FLUTTER_PACKAGE_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/.." REALPATH)
set(ERIKA_NATIVE_HEADER_DIR
  "${ERIKA_FLUTTER_PACKAGE_DIR}/native/include")
if(NOT EXISTS "${ERIKA_NATIVE_HEADER_DIR}/erika.h")
  message(FATAL_ERROR
    "Erika C API header is missing from the Flutter package: "
    "${ERIKA_NATIVE_HEADER_DIR}/erika.h")
endif()

list(APPEND PLUGIN_SOURCES
  "erika_flutter_plugin.cpp"
  "erika_flutter_plugin.h"
  "erika_windows_smtc.cpp"
  "erika_windows_smtc.h"
)

add_library(${PLUGIN_NAME} SHARED
  "include/erika_flutter/erika_flutter_plugin_c_api.h"
  "erika_flutter_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})
if(MSVC)
  target_compile_options(${PLUGIN_NAME} PRIVATE /utf-8)
endif()

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE
  FLUTTER_PLUGIN_IMPL
  _WIN32_WINNT=0x0A00
  WINVER=0x0A00
  _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${ERIKA_NATIVE_HEADER_DIR}")
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter flutter_wrapper_plugin runtimeobject windowsapp dcomp shcore shlwapi)

set(ERIKA_WINDOWS_ARCH "" CACHE STRING
  "Erika Windows architecture: x64, x86_64, arm64, or aarch64")
set(ERIKA_NATIVE_TARGET "" CACHE STRING
  "Erika Rust target override for the native runtime")
set(ERIKA_NATIVE_PROFILE "lgpl" CACHE STRING
  "Erika native dependency profile")

if(ERIKA_NATIVE_TARGET STREQUAL "")
  if(NOT ERIKA_WINDOWS_ARCH STREQUAL "")
    set(_ERIKA_WINDOWS_ARCH "${ERIKA_WINDOWS_ARCH}")
  elseif(DEFINED ENV{ERIKA_WINDOWS_ARCH} AND
      NOT "$ENV{ERIKA_WINDOWS_ARCH}" STREQUAL "")
    set(_ERIKA_WINDOWS_ARCH "$ENV{ERIKA_WINDOWS_ARCH}")
  elseif(NOT CMAKE_GENERATOR_PLATFORM STREQUAL "")
    set(_ERIKA_WINDOWS_ARCH "${CMAKE_GENERATOR_PLATFORM}")
  elseif(DEFINED CMAKE_VS_PLATFORM_NAME AND
      NOT CMAKE_VS_PLATFORM_NAME STREQUAL "")
    set(_ERIKA_WINDOWS_ARCH "${CMAKE_VS_PLATFORM_NAME}")
  else()
    set(_ERIKA_WINDOWS_ARCH "${CMAKE_SYSTEM_PROCESSOR}")
  endif()
  string(TOLOWER "${_ERIKA_WINDOWS_ARCH}" _ERIKA_WINDOWS_ARCH)
  if(_ERIKA_WINDOWS_ARCH MATCHES "^(x64|amd64|x86_64)$")
    set(ERIKA_NATIVE_TARGET "x86_64-pc-windows-msvc")
  elseif(_ERIKA_WINDOWS_ARCH MATCHES "^(arm64|aarch64)$")
    set(ERIKA_NATIVE_TARGET "aarch64-pc-windows-msvc")
  else()
    message(FATAL_ERROR
      "Unsupported Erika Windows architecture: ${_ERIKA_WINDOWS_ARCH}. "
      "Set ERIKA_WINDOWS_ARCH to x64 or arm64.")
  endif()
endif()

if(NOT ERIKA_NATIVE_TARGET STREQUAL "x86_64-pc-windows-msvc" AND
    NOT ERIKA_NATIVE_TARGET STREQUAL "aarch64-pc-windows-msvc")
  message(FATAL_ERROR
    "Unsupported Erika Windows Rust target: ${ERIKA_NATIVE_TARGET}")
endif()

set(ERIKA_RUNTIME_DIR
  "${CMAKE_CURRENT_BINARY_DIR}/erika_runtime")
set(ERIKA_CAPI_DLL_PATH
  "${ERIKA_RUNTIME_DIR}/erika_capi.dll")
add_custom_target(erika_capi_runtime
  COMMAND "${CMAKE_COMMAND}"
    "-DERIKA_PACKAGE_ROOT=${ERIKA_FLUTTER_PACKAGE_DIR}"
    "-DERIKA_RUNTIME_OUT=${ERIKA_CAPI_DLL_PATH}"
    "-DERIKA_CACHE_ROOT=${CMAKE_CURRENT_BINARY_DIR}/erika_prebuilt_cache"
    "-DERIKA_NATIVE_TARGET=${ERIKA_NATIVE_TARGET}"
    "-DERIKA_NATIVE_PROFILE=${ERIKA_NATIVE_PROFILE}"
    "-DERIKA_BUILD_CONFIG=$<CONFIG>"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/build_erika_runtime.cmake"
  WORKING_DIRECTORY "${ERIKA_FLUTTER_PACKAGE_DIR}"
  COMMENT "Preparing Erika native runtime for $<CONFIG>"
  VERBATIM
)
add_dependencies(${PLUGIN_NAME} erika_capi_runtime)

set(erika_flutter_bundled_libraries
  "${ERIKA_CAPI_DLL_PATH}"
  PARENT_SCOPE
)
