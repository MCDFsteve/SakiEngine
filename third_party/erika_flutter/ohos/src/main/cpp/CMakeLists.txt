cmake_minimum_required(VERSION 3.17)
project(erika_flutter LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(PLUGIN_NAME erika_flutter_plugin)

get_filename_component(ERIKA_PACKAGE_ROOT
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../.." REALPATH)
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
erika_read_artifact_property(
  ERIKA_OPENHARMONY_ARM64_SHA256 ERIKA_DEFAULT_PREBUILT_SHA256)
set(ERIKA_DEFAULT_PREBUILT_TAG "v${ERIKA_NATIVE_VERSION}")
set(ERIKA_TARGET aarch64-unknown-linux-ohos)
set(ERIKA_RUNTIME "")

set(ERIKA_USE_PREBUILT ON)
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
  string(REGEX REPLACE "[^A-Za-z0-9._-]" "_" ERIKA_PREBUILT_CACHE_KEY
    "${ERIKA_PREBUILT_TAG}"
  )
  set(ERIKA_PREBUILT_DIR
    "${CMAKE_CURRENT_BINARY_DIR}/erika-prebuilt-${ERIKA_PREBUILT_CACHE_KEY}"
  )
  set(ERIKA_PREBUILT_ZIP
    "${ERIKA_PREBUILT_DIR}/erika-capi-openharmony-arm64.zip"
  )
  set(ERIKA_PREBUILT_RUNTIME
    "${ERIKA_PREBUILT_DIR}/erika-capi-openharmony-arm64/lib/liberika_capi.so"
  )
  set(ERIKA_PREBUILT_URL
    "https://github.com/AimesSoft/Erika/releases/download/${ERIKA_PREBUILT_TAG}/erika-capi-openharmony-arm64.zip"
  )

  if(EXISTS "${ERIKA_PREBUILT_ZIP}")
    file(SHA256 "${ERIKA_PREBUILT_ZIP}" ERIKA_CACHED_PREBUILT_SHA256)
    if(NOT ERIKA_CACHED_PREBUILT_SHA256 STREQUAL ERIKA_PREBUILT_SHA256)
      file(REMOVE "${ERIKA_PREBUILT_ZIP}" "${ERIKA_PREBUILT_RUNTIME}")
    endif()
  elseif(EXISTS "${ERIKA_PREBUILT_RUNTIME}")
    file(REMOVE "${ERIKA_PREBUILT_RUNTIME}")
  endif()
  if(NOT EXISTS "${ERIKA_PREBUILT_RUNTIME}")
    file(MAKE_DIRECTORY "${ERIKA_PREBUILT_DIR}")
    message(STATUS "Erika: downloading prebuilt ${ERIKA_PREBUILT_URL}")
    file(
      DOWNLOAD "${ERIKA_PREBUILT_URL}" "${ERIKA_PREBUILT_ZIP}"
      STATUS ERIKA_PREBUILT_DOWNLOAD_STATUS
      EXPECTED_HASH "SHA256=${ERIKA_PREBUILT_SHA256}"
      SHOW_PROGRESS
      TLS_VERIFY ON
      TIMEOUT 120
      INACTIVITY_TIMEOUT 30
    )
    list(GET ERIKA_PREBUILT_DOWNLOAD_STATUS 0 ERIKA_PREBUILT_DOWNLOAD_CODE)
    if(ERIKA_PREBUILT_DOWNLOAD_CODE EQUAL 0)
      execute_process(
        COMMAND "${CMAKE_COMMAND}" -E tar xf "${ERIKA_PREBUILT_ZIP}"
        WORKING_DIRECTORY "${ERIKA_PREBUILT_DIR}"
        RESULT_VARIABLE ERIKA_PREBUILT_EXTRACT_STATUS
      )
      if(NOT ERIKA_PREBUILT_EXTRACT_STATUS EQUAL 0)
        message(FATAL_ERROR
          "Failed to extract Erika prebuilt ${ERIKA_PREBUILT_TAG}")
      endif()
    else()
      list(GET ERIKA_PREBUILT_DOWNLOAD_STATUS 1 ERIKA_PREBUILT_DOWNLOAD_MESSAGE)
      message(FATAL_ERROR
        "Erika prebuilt download or checksum verification failed: ${ERIKA_PREBUILT_DOWNLOAD_MESSAGE}. Set ERIKA_FORCE_SOURCE_BUILD=1 only from an Erika checkout.")
    endif()
  endif()

  set(ERIKA_PREBUILT_RUNTIME_VALID OFF)
  if(EXISTS "${ERIKA_PREBUILT_RUNTIME}")
    file(SIZE "${ERIKA_PREBUILT_RUNTIME}" ERIKA_PREBUILT_RUNTIME_SIZE)
    if(ERIKA_PREBUILT_RUNTIME_SIZE GREATER 0)
      set(ERIKA_PREBUILT_RUNTIME_VALID ON)
    endif()
  endif()
  if(ERIKA_PREBUILT_RUNTIME_VALID)
    set(ERIKA_RUNTIME "${ERIKA_PREBUILT_RUNTIME}")
    message(STATUS "Erika: using prebuilt ${ERIKA_PREBUILT_TAG}")
  else()
    message(FATAL_ERROR
      "Erika prebuilt ${ERIKA_PREBUILT_TAG} did not contain liberika_capi.so")
  endif()
else()
  set(ERIKA_USE_PREBUILT OFF)
  if(NOT "$ENV{ERIKA_REPO_ROOT}" STREQUAL "")
    file(TO_CMAKE_PATH "$ENV{ERIKA_REPO_ROOT}" ERIKA_ROOT)
  else()
    get_filename_component(ERIKA_ROOT "${ERIKA_PACKAGE_ROOT}/../.." REALPATH)
  endif()
  if(NOT EXISTS "${ERIKA_ROOT}/crates/erika_capi/Cargo.toml")
    message(FATAL_ERROR
      "ERIKA_FORCE_SOURCE_BUILD=1 requires an Erika checkout; set ERIKA_REPO_ROOT")
  endif()
  set(ERIKA_RUNTIME
    "${ERIKA_ROOT}/target/${ERIKA_TARGET}/release/liberika_capi.so")
endif()

if(NOT DEFINED OHOS_SDK_NATIVE)
  message(FATAL_ERROR "OHOS_SDK_NATIVE is required to build Erika for OpenHarmony")
endif()

set(OHOS_LLVM_BIN "${OHOS_SDK_NATIVE}/llvm/bin")
set(OHOS_CXX_INCLUDE
  "${OHOS_SDK_NATIVE}/llvm/include/libcxx-ohos/include/c++/v1"
)
if(NOT EXISTS "${OHOS_CXX_INCLUDE}/vector")
  set(OHOS_CXX_INCLUDE "${OHOS_SDK_NATIVE}/llvm/include/c++/v1")
endif()
set(OHOS_BINDGEN_ARGS
  "--target=${ERIKA_TARGET} --sysroot=${OHOS_SDK_NATIVE}/sysroot -isystem ${OHOS_CXX_INCLUDE}"
)
if(NOT ERIKA_USE_PREBUILT)
  find_program(CARGO_EXECUTABLE cargo REQUIRED)
  file(GLOB_RECURSE ERIKA_RUST_SOURCES CONFIGURE_DEPENDS
    "${ERIKA_ROOT}/crates/*.rs"
    "${ERIKA_ROOT}/third_party/wgpu-hal/*.rs"
    "${ERIKA_ROOT}/xtask/*.rs"
  )
  list(APPEND ERIKA_RUST_SOURCES
    "${ERIKA_ROOT}/Cargo.toml"
    "${ERIKA_ROOT}/Cargo.lock"
  )

  add_custom_command(
    OUTPUT "${ERIKA_RUNTIME}"
    COMMAND
      "${CMAKE_COMMAND}" -E env
        "OHOS_NDK_HOME=${OHOS_SDK_NATIVE}"
        "${CARGO_EXECUTABLE}" run -q -p xtask --
        deps build --profile lgpl --target "${ERIKA_TARGET}"
    COMMAND
      "${CMAKE_COMMAND}" -E env
        "ERIKA_NATIVE_PROFILE=lgpl"
        "ERIKA_NATIVE_TARGET=${ERIKA_TARGET}"
        "OHOS_NDK_HOME=${OHOS_SDK_NATIVE}"
        "LIBCLANG_PATH=${OHOS_SDK_NATIVE}/llvm/lib"
        "BINDGEN_EXTRA_CLANG_ARGS_aarch64_unknown_linux_ohos=${OHOS_BINDGEN_ARGS}"
        "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER=${OHOS_LLVM_BIN}/aarch64-unknown-linux-ohos-clang"
        "CC_aarch64_unknown_linux_ohos=${OHOS_LLVM_BIN}/aarch64-unknown-linux-ohos-clang"
        "CXX_aarch64_unknown_linux_ohos=${OHOS_LLVM_BIN}/aarch64-unknown-linux-ohos-clang++"
        "AR_aarch64_unknown_linux_ohos=${OHOS_LLVM_BIN}/llvm-ar"
        "${CARGO_EXECUTABLE}" build -p erika_capi
        --target "${ERIKA_TARGET}" --release
        --no-default-features --features wgpu
    WORKING_DIRECTORY "${ERIKA_ROOT}"
    DEPENDS ${ERIKA_RUST_SOURCES}
    COMMENT "Building Erika OpenHarmony runtime"
    VERBATIM
  )
  add_custom_target(erika_ohos_runtime DEPENDS "${ERIKA_RUNTIME}")
endif()

add_library(erika_capi SHARED IMPORTED GLOBAL)
set_target_properties(erika_capi PROPERTIES IMPORTED_LOCATION "${ERIKA_RUNTIME}")
if(NOT ERIKA_USE_PREBUILT)
  add_dependencies(erika_capi erika_ohos_runtime)
endif()

add_library(${PLUGIN_NAME} SHARED erika_flutter_plugin.cpp)
if(NOT ERIKA_USE_PREBUILT)
  add_dependencies(${PLUGIN_NAME} erika_ohos_runtime)
endif()
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  OUTPUT_NAME "erika_flutter"
)
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${ERIKA_PACKAGE_ROOT}/native/include"
)
target_compile_options(${PLUGIN_NAME} PRIVATE
  -fno-exceptions
  -ffunction-sections
  -fdata-sections
)
target_link_options(${PLUGIN_NAME} PRIVATE -Wl,--gc-sections)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  erika_capi
  libace_napi.z.so
  libnative_window.so
  libhilog_ndk.z.so
)
add_custom_command(
  TARGET ${PLUGIN_NAME} POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${ERIKA_RUNTIME}" "$<TARGET_FILE_DIR:${PLUGIN_NAME}>/liberika_capi.so"
  COMMENT "Staging Erika OpenHarmony runtime beside the Flutter plugin"
  VERBATIM
)
