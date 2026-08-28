cmake_minimum_required(VERSION 3.14)

foreach(required ERIKA_PACKAGE_ROOT ERIKA_RUNTIME_OUT ERIKA_CACHE_ROOT
    ERIKA_NATIVE_TARGET)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "${required} is required")
  endif()
endforeach()
if(NOT DEFINED ERIKA_NATIVE_PROFILE OR ERIKA_NATIVE_PROFILE STREQUAL "")
  set(ERIKA_NATIVE_PROFILE "lgpl")
endif()
if(NOT DEFINED ERIKA_BUILD_CONFIG OR ERIKA_BUILD_CONFIG STREQUAL "")
  set(ERIKA_BUILD_CONFIG "Release")
endif()
if(NOT ERIKA_NATIVE_TARGET STREQUAL "x86_64-pc-windows-msvc" AND
    NOT ERIKA_NATIVE_TARGET STREQUAL "aarch64-pc-windows-msvc")
  message(FATAL_ERROR "Unsupported Erika Windows target: ${ERIKA_NATIVE_TARGET}")
endif()

if(NOT "$ENV{ERIKA_FORCE_SOURCE_BUILD}" STREQUAL "1")
  if(ERIKA_NATIVE_TARGET STREQUAL "x86_64-pc-windows-msvc")
    set(ERIKA_BUNDLED_RUNTIME
      "${ERIKA_PACKAGE_ROOT}/native/windows/x64/erika_capi.dll")
    set(ERIKA_BUNDLED_SHA256 "6c328865d050212c92c81ce202d48d024b4f667b1bb7da7ac23f7c3b084e6847")
  else()
    set(ERIKA_BUNDLED_RUNTIME
      "${ERIKA_PACKAGE_ROOT}/native/windows/arm64/erika_capi.dll")
    set(ERIKA_BUNDLED_SHA256 "")
  endif()
  if(NOT EXISTS "${ERIKA_BUNDLED_RUNTIME}")
    message(FATAL_ERROR
      "Bundled Erika runtime is missing: ${ERIKA_BUNDLED_RUNTIME}. "
      "SakiEngine desktop builds never download native binaries.")
  endif()
  file(SHA256 "${ERIKA_BUNDLED_RUNTIME}" ERIKA_BUNDLED_ACTUAL_SHA256)
  if(ERIKA_BUNDLED_SHA256 STREQUAL "" OR
      NOT ERIKA_BUNDLED_ACTUAL_SHA256 STREQUAL ERIKA_BUNDLED_SHA256)
    message(FATAL_ERROR "Bundled Erika runtime checksum mismatch")
  endif()
  get_filename_component(ERIKA_RUNTIME_DIR "${ERIKA_RUNTIME_OUT}" DIRECTORY)
  file(MAKE_DIRECTORY "${ERIKA_RUNTIME_DIR}")
  configure_file("${ERIKA_BUNDLED_RUNTIME}" "${ERIKA_RUNTIME_OUT}" COPYONLY)
  message(STATUS "Erika: using bundled offline runtime -> ${ERIKA_RUNTIME_OUT}")
  return()
endif()

set(ERIKA_ARTIFACT_MANIFEST
  "${ERIKA_PACKAGE_ROOT}/native_artifacts.properties")
if(NOT EXISTS "${ERIKA_ARTIFACT_MANIFEST}")
  message(FATAL_ERROR
    "Erika native artifact manifest is missing: ${ERIKA_ARTIFACT_MANIFEST}")
endif()

function(erika_read_artifact_property key output)
  file(STRINGS "${ERIKA_ARTIFACT_MANIFEST}" value REGEX "^${key}=")
  if(NOT value)
    message(FATAL_ERROR "Missing ${key} in ${ERIKA_ARTIFACT_MANIFEST}")
  endif()
  list(GET value 0 value)
  string(REGEX REPLACE "^[^=]+=" "" value "${value}")
  set(${output} "${value}" PARENT_SCOPE)
endfunction()

erika_read_artifact_property(ERIKA_NATIVE_VERSION ERIKA_NATIVE_VERSION)
set(ERIKA_DEFAULT_PREBUILT_TAG "v${ERIKA_NATIVE_VERSION}")
if(ERIKA_NATIVE_TARGET STREQUAL "aarch64-pc-windows-msvc")
  set(ERIKA_ASSET_ARCH "arm64")
  erika_read_artifact_property(
    ERIKA_WINDOWS_ARM64_SHA256 ERIKA_DEFAULT_PREBUILT_SHA256)
else()
  set(ERIKA_ASSET_ARCH "x64")
  erika_read_artifact_property(
    ERIKA_WINDOWS_X64_SHA256 ERIKA_DEFAULT_PREBUILT_SHA256)
endif()

if(NOT "$ENV{ERIKA_FORCE_SOURCE_BUILD}" STREQUAL "1")
  if("$ENV{ERIKA_PREBUILT_TAG}" STREQUAL "")
    set(ERIKA_PREBUILT_TAG "${ERIKA_DEFAULT_PREBUILT_TAG}")
  else()
    set(ERIKA_PREBUILT_TAG "$ENV{ERIKA_PREBUILT_TAG}")
  endif()
  if("$ENV{ERIKA_PREBUILT_SHA256}" STREQUAL "")
    if(NOT ERIKA_PREBUILT_TAG STREQUAL ERIKA_DEFAULT_PREBUILT_TAG)
      message(FATAL_ERROR
        "ERIKA_PREBUILT_SHA256 is required when ERIKA_PREBUILT_TAG overrides ${ERIKA_DEFAULT_PREBUILT_TAG}")
    endif()
    set(ERIKA_PREBUILT_SHA256 "${ERIKA_DEFAULT_PREBUILT_SHA256}")
  else()
    set(ERIKA_PREBUILT_SHA256 "$ENV{ERIKA_PREBUILT_SHA256}")
  endif()

  string(REGEX REPLACE "[^A-Za-z0-9._-]" "_"
    ERIKA_CACHE_TAG "${ERIKA_PREBUILT_TAG}")
  set(ERIKA_WORK
    "${ERIKA_CACHE_ROOT}/${ERIKA_CACHE_TAG}-${ERIKA_ASSET_ARCH}")
  set(ERIKA_ZIP "${ERIKA_WORK}/bundle.zip")
  set(ERIKA_URL
    "https://github.com/AimesSoft/Erika/releases/download/${ERIKA_PREBUILT_TAG}/erika-capi-windows-${ERIKA_ASSET_ARCH}.zip")

  if(EXISTS "${ERIKA_ZIP}")
    file(SHA256 "${ERIKA_ZIP}" ERIKA_CACHED_SHA256)
    if(NOT ERIKA_CACHED_SHA256 STREQUAL ERIKA_PREBUILT_SHA256)
      file(REMOVE "${ERIKA_ZIP}" "${ERIKA_RUNTIME_OUT}")
    endif()
  endif()
  if(NOT EXISTS "${ERIKA_ZIP}")
    file(MAKE_DIRECTORY "${ERIKA_WORK}")
    message(STATUS "Erika: downloading prebuilt ${ERIKA_URL}")
    file(DOWNLOAD "${ERIKA_URL}" "${ERIKA_ZIP}"
      EXPECTED_HASH "SHA256=${ERIKA_PREBUILT_SHA256}"
      STATUS ERIKA_DOWNLOAD_STATUS
      SHOW_PROGRESS
      TLS_VERIFY ON
      TIMEOUT 900)
    list(GET ERIKA_DOWNLOAD_STATUS 0 ERIKA_DOWNLOAD_CODE)
    if(NOT ERIKA_DOWNLOAD_CODE EQUAL 0)
      list(GET ERIKA_DOWNLOAD_STATUS 1 ERIKA_DOWNLOAD_MESSAGE)
      message(FATAL_ERROR
        "Erika prebuilt download or checksum verification failed: ${ERIKA_DOWNLOAD_MESSAGE}. Set ERIKA_FORCE_SOURCE_BUILD=1 only from an Erika checkout.")
    endif()
  endif()

  if(NOT EXISTS "${ERIKA_RUNTIME_OUT}")
    file(REMOVE_RECURSE "${ERIKA_WORK}/unpacked")
    file(MAKE_DIRECTORY "${ERIKA_WORK}/unpacked")
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E tar xf "${ERIKA_ZIP}"
      WORKING_DIRECTORY "${ERIKA_WORK}/unpacked"
      RESULT_VARIABLE ERIKA_EXTRACT_RESULT)
    if(NOT ERIKA_EXTRACT_RESULT EQUAL 0)
      message(FATAL_ERROR
        "Failed to extract Erika prebuilt ${ERIKA_PREBUILT_TAG}")
    endif()
    file(GLOB_RECURSE ERIKA_FOUND_DLL
      "${ERIKA_WORK}/unpacked/*/lib/erika_capi.dll")
    if(NOT ERIKA_FOUND_DLL)
      message(FATAL_ERROR
        "Erika prebuilt ${ERIKA_PREBUILT_TAG} did not contain erika_capi.dll")
    endif()
    list(GET ERIKA_FOUND_DLL 0 ERIKA_SOURCE_DLL)
    get_filename_component(ERIKA_RUNTIME_DIR "${ERIKA_RUNTIME_OUT}" DIRECTORY)
    file(MAKE_DIRECTORY "${ERIKA_RUNTIME_DIR}")
    file(COPY "${ERIKA_SOURCE_DLL}" DESTINATION "${ERIKA_RUNTIME_DIR}")
  endif()
  message(STATUS
    "Erika: using verified prebuilt ${ERIKA_PREBUILT_TAG} -> ${ERIKA_RUNTIME_OUT}")
  return()
endif()

if(NOT "$ENV{ERIKA_REPO_ROOT}" STREQUAL "")
  file(TO_CMAKE_PATH "$ENV{ERIKA_REPO_ROOT}" ERIKA_REPO_ROOT)
else()
  get_filename_component(ERIKA_REPO_ROOT
    "${ERIKA_PACKAGE_ROOT}/../.." REALPATH)
endif()
if(NOT EXISTS "${ERIKA_REPO_ROOT}/crates/erika_capi/Cargo.toml")
  message(FATAL_ERROR
    "ERIKA_FORCE_SOURCE_BUILD=1 requires an Erika checkout; set ERIKA_REPO_ROOT")
endif()
find_program(CARGO_EXECUTABLE cargo REQUIRED)

set(ERIKA_NATIVE_DIST_DIR
  "${ERIKA_REPO_ROOT}/third_party/dist/${ERIKA_NATIVE_TARGET}/${ERIKA_NATIVE_PROFILE}")
set(ERIKA_FFMPEG_DIR "${ERIKA_NATIVE_DIST_DIR}/ffmpeg")
set(ERIKA_LIBASS_DIR "${ERIKA_NATIVE_DIST_DIR}/libass")
set(ERIKA_FREETYPE_DIR "${ERIKA_NATIVE_DIST_DIR}/freetype")
set(ERIKA_HARFBUZZ_DIR "${ERIKA_NATIVE_DIST_DIR}/harfbuzz")
set(ERIKA_FRIBIDI_DIR "${ERIKA_NATIVE_DIST_DIR}/fribidi")

function(erika_native_deps_ready output)
  set(ready TRUE)
  foreach(path
      "${ERIKA_FFMPEG_DIR}/include/libavutil/version.h"
      "${ERIKA_LIBASS_DIR}/lib"
      "${ERIKA_FREETYPE_DIR}/lib"
      "${ERIKA_HARFBUZZ_DIR}/lib"
      "${ERIKA_FRIBIDI_DIR}/lib")
    if(NOT EXISTS "${path}")
      set(ready FALSE)
    endif()
  endforeach()
  set(${output} "${ready}" PARENT_SCOPE)
endfunction()

erika_native_deps_ready(ERIKA_NATIVE_DEPS_READY)
if(NOT ERIKA_NATIVE_DEPS_READY)
  execute_process(
    COMMAND "${CARGO_EXECUTABLE}" run -p xtask -- deps build
      --profile "${ERIKA_NATIVE_PROFILE}"
      --target "${ERIKA_NATIVE_TARGET}"
      --all
    WORKING_DIRECTORY "${ERIKA_REPO_ROOT}"
    RESULT_VARIABLE ERIKA_DEPS_RESULT)
  if(NOT ERIKA_DEPS_RESULT EQUAL 0)
    message(FATAL_ERROR
      "Failed to build Erika native dependencies (exit ${ERIKA_DEPS_RESULT})")
  endif()
endif()

set(ERIKA_CARGO_ARGS build -p erika_capi --target "${ERIKA_NATIVE_TARGET}")
if(NOT ERIKA_BUILD_CONFIG STREQUAL "Debug")
  list(APPEND ERIKA_CARGO_ARGS --release)
  set(ERIKA_CARGO_PROFILE release)
else()
  set(ERIKA_CARGO_PROFILE debug)
endif()
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E env
    "ERIKA_NATIVE_TARGET=${ERIKA_NATIVE_TARGET}"
    "ERIKA_NATIVE_PROFILE=${ERIKA_NATIVE_PROFILE}"
    "ERIKA_FFMPEG_DIR=${ERIKA_FFMPEG_DIR}"
    "ERIKA_LIBASS_DIR=${ERIKA_LIBASS_DIR}"
    "ERIKA_FREETYPE_DIR=${ERIKA_FREETYPE_DIR}"
    "ERIKA_HARFBUZZ_DIR=${ERIKA_HARFBUZZ_DIR}"
    "ERIKA_FRIBIDI_DIR=${ERIKA_FRIBIDI_DIR}"
    "${CARGO_EXECUTABLE}" ${ERIKA_CARGO_ARGS}
  WORKING_DIRECTORY "${ERIKA_REPO_ROOT}"
  RESULT_VARIABLE ERIKA_CAPI_RESULT)
if(NOT ERIKA_CAPI_RESULT EQUAL 0)
  message(FATAL_ERROR
    "Failed to build Erika C API runtime (exit ${ERIKA_CAPI_RESULT})")
endif()

set(ERIKA_SOURCE_DLL
  "${ERIKA_REPO_ROOT}/target/${ERIKA_NATIVE_TARGET}/${ERIKA_CARGO_PROFILE}/erika_capi.dll")
if(NOT EXISTS "${ERIKA_SOURCE_DLL}")
  message(FATAL_ERROR "Erika source build did not produce ${ERIKA_SOURCE_DLL}")
endif()
get_filename_component(ERIKA_RUNTIME_DIR "${ERIKA_RUNTIME_OUT}" DIRECTORY)
file(MAKE_DIRECTORY "${ERIKA_RUNTIME_DIR}")
file(COPY "${ERIKA_SOURCE_DLL}" DESTINATION "${ERIKA_RUNTIME_DIR}")
