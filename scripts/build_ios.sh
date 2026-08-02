#!/usr/bin/env bash
# Build libcore_entropy.a for iOS device and simulator, packaged as an
# .xcframework ready to drop into a Flutter plugin or Xcode project.
#
#   ./scripts/build_ios.sh [MIN_IOS_VERSION]
#
# Core's HAVE_GETENTROPY_RAND branch is used. iOS exports no getentropy(), so
# shim/apple_getentropy.cpp supplies it over CCRandomGenerateBytes. There is no
# /dev/urandom path — see shim/bitcoin-build-config.h.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MIN="${1:-13.0}"
OUT=build/ios
rm -rf "$OUT"
mkdir -p "$OUT"

SRC=$(make -s print-sources)

echo "iOS deployment target $MIN"
echo

build_slice() {
  local name="$1" sdk="$2" target="$3"
  local sysroot obj lib
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  obj="$OUT/obj-$name"
  lib="$OUT/libcore_entropy-$name.a"
  mkdir -p "$obj"

  local objs=()
  for f in $SRC; do
    local o="$obj/$(echo "$f" | tr '/' '_' | sed 's/\.cpp$/.o/')"
    xcrun --sdk "$sdk" clang++ -std=c++20 -O2 \
      -target "$target" -isysroot "$sysroot" \
      -fembed-bitcode-marker -ffunction-sections -fdata-sections \
      -Wall -Wextra -Wno-unused-parameter -Wno-unused-function \
      -Ishim -Icore -Isrc -c "$f" -o "$o"
    objs+=("$o")
  done

  xcrun --sdk "$sdk" libtool -static -o "$lib" "${objs[@]}" 2>/dev/null
  printf '  %-22s %s\n' "$name" "$(lipo -archs "$lib" 2>/dev/null || echo '?')"
  echo "$lib"
}

DEV=$(build_slice device iphoneos "arm64-apple-ios$MIN" | tail -1)
SIM_ARM=$(build_slice sim-arm64 iphonesimulator "arm64-apple-ios$MIN-simulator" | tail -1)
SIM_X64=$(build_slice sim-x86_64 iphonesimulator "x86_64-apple-ios$MIN-simulator" | tail -1)

SIM_FAT="$OUT/libcore_entropy-simulator.a"
lipo -create "$SIM_ARM" "$SIM_X64" -output "$SIM_FAT"
printf '  %-22s %s\n' "simulator (fat)" "$(lipo -archs "$SIM_FAT")"

mkdir -p "$OUT/include"
cp src/core_entropy.h "$OUT/include/"

xcodebuild -create-xcframework \
  -library "$DEV"     -headers "$OUT/include" \
  -library "$SIM_FAT" -headers "$OUT/include" \
  -output "$OUT/CoreEntropy.xcframework" >/dev/null

echo
fail=0
for lib in "$DEV" "$SIM_FAT"; do
  if strings "$lib" | grep -q '/dev/urandom'; then
    echo "  FAIL: /dev/urandom present in $(basename "$lib")"; fail=1
  fi
  if ! nm "$lib" 2>/dev/null | grep -q '_core_entropy_get_strong'; then
    echo "  FAIL: core_entropy_get_strong missing from $(basename "$lib")"; fail=1
  fi
  if ! nm "$lib" 2>/dev/null | grep -q 'CCRandomGenerateBytes'; then
    echo "  FAIL: CCRandomGenerateBytes not referenced in $(basename "$lib")"; fail=1
  fi
done

echo "  xcframework: $OUT/CoreEntropy.xcframework"
echo
[ "$fail" -eq 0 ] && echo "PASS: device + simulator built, no /dev/urandom, CCRandomGenerateBytes wired." \
                  || echo "FAIL"
exit $fail
