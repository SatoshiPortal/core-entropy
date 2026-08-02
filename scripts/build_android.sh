#!/usr/bin/env bash
# Cross-compile libcore_entropy.so for every Android ABI.
#
#   ANDROID_NDK_HOME=/path/to/ndk ./scripts/build_android.sh [API_LEVEL]
#
# Defaults to API 21, the NDK's own floor. Core's getrandom(2) branch is used
# at every level; below 28 the symbol comes from shim/android_getrandom.cpp
# because bionic gates the libc wrapper. There is no /dev/urandom path at any
# API level — see shim/bitcoin-build-config.h.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

API="${1:-21}"

NDK="${ANDROID_NDK_HOME:-}"
if [ -z "$NDK" ]; then
  NDK=$(ls -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/ndk/* 2>/dev/null | sort -V | tail -1 || true)
fi
[ -n "$NDK" ] && [ -d "$NDK" ] || { echo "ANDROID_NDK_HOME not set and no NDK found"; exit 1; }

case "$(uname -s)" in
  Darwin) HOST_TAG=darwin-x86_64 ;;
  Linux)  HOST_TAG=linux-x86_64 ;;
  *) echo "unsupported build host"; exit 1 ;;
esac
TC="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
[ -d "$TC" ] || { echo "toolchain not found at $TC"; exit 1; }

echo "NDK  $NDK"
echo "API  $API"
echo

SRC=$(make -s print-sources)

build_abi() {
  local abi="$1" triple="$2"
  local cxx="$TC/${triple}${API}-clang++"
  [ -x "$cxx" ] || { echo "  no compiler for $abi at $cxx"; return 1; }

  local out="build/android/$abi"
  mkdir -p "$out"

  local objs=()
  for f in $SRC; do
    local o="$out/$(echo "$f" | tr '/' '_' | sed 's/\.cpp$/.o/')"
    "$cxx" -std=c++20 -O2 -fPIC -ffunction-sections -fdata-sections \
      -Wall -Wextra -Wno-unused-parameter \
      -Ishim -Icore -Isrc -c "$f" -o "$o"
    objs+=("$o")
  done

  "$cxx" -shared -Wl,--gc-sections -Wl,-z,max-page-size=16384 \
    -o "$out/libcore_entropy.so" "${objs[@]}"

  local size arch
  size=$(wc -c < "$out/libcore_entropy.so" | tr -d ' ')
  arch=$("$TC/llvm-readelf" -h "$out/libcore_entropy.so" | awk '/Machine:/{ $1=""; print substr($0,2) }')
  printf '  %-12s %-28s %8s bytes\n' "$abi" "$arch" "$size"

  # The whole point of the build config: this branch must not be reachable.
  if "$TC/llvm-strings" "$out/libcore_entropy.so" | grep -q '/dev/urandom'; then
    echo "     FAIL: /dev/urandom present in $abi binary"
    return 1
  fi
  if ! "$TC/llvm-nm" -D --defined-only "$out/libcore_entropy.so" | grep -q core_entropy_get_strong; then
    echo "     FAIL: core_entropy_get_strong not exported in $abi"
    return 1
  fi
}

fail=0
build_abi arm64-v8a   aarch64-linux-android   || fail=1
build_abi armeabi-v7a armv7a-linux-androideabi || fail=1
build_abi x86_64      x86_64-linux-android     || fail=1
build_abi x86         i686-linux-android       || fail=1

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS: 4 ABIs built, no /dev/urandom, symbols exported."
else
  echo "FAIL"
fi
exit $fail
