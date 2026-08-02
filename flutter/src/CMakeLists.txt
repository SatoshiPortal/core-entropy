# Builds libcore_entropy.so for Flutter's Android (Gradle/CMake) toolchain.
# The source list is the same one the Makefile and the cross-compile scripts
# use; there is exactly one set of sources for every platform.
cmake_minimum_required(VERSION 3.18)
project(core_entropy LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

get_filename_component(REPO "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)

set(CORE_SRC
  ${REPO}/core/random.cpp
  ${REPO}/core/clientversion.cpp
  ${REPO}/core/randomenv.cpp
  ${REPO}/core/crypto/chacha20.cpp
  ${REPO}/core/crypto/sha256.cpp
  ${REPO}/core/crypto/sha512.cpp
  ${REPO}/core/crypto/hex_base.cpp
  ${REPO}/core/support/cleanse.cpp
  ${REPO}/core/support/lockedpool.cpp
  ${REPO}/core/sync.cpp
  ${REPO}/core/logging.cpp
  ${REPO}/core/uint256.cpp
  ${REPO}/core/util/check.cpp
  ${REPO}/core/util/strencodings.cpp
  ${REPO}/core/util/string.cpp
  ${REPO}/core/util/time.cpp
  ${REPO}/core/util/threadnames.cpp
  ${REPO}/core/util/syserror.cpp
  ${REPO}/core/util/fs.cpp
)

add_library(core_entropy SHARED
  ${CORE_SRC}
  ${REPO}/src/core_entropy.cpp
  ${REPO}/shim/android_getrandom.cpp
  ${REPO}/shim/apple_getentropy.cpp
)

target_include_directories(core_entropy PRIVATE
  ${REPO}/shim ${REPO}/core ${REPO}/src)

target_compile_options(core_entropy PRIVATE
  -O2 -ffunction-sections -fdata-sections -Wall -Wextra
  -Wno-unused-parameter -Wno-unused-function)

target_link_options(core_entropy PRIVATE
  -Wl,--gc-sections -Wl,-z,max-page-size=16384)

set_target_properties(core_entropy PROPERTIES OUTPUT_NAME "core_entropy")

# The Coldcard failure mode was a build that silently selected a weaker RNG
# and still produced valid-looking output. Fail the build here rather than
# trust that the right branch was taken.
add_custom_command(TARGET core_entropy POST_BUILD
  COMMAND ${CMAKE_COMMAND}
    -DLIB=$<TARGET_FILE:core_entropy>
    -DNM=${CMAKE_NM}
    -P ${CMAKE_CURRENT_LIST_DIR}/assert_no_fallback.cmake
  VERBATIM)
