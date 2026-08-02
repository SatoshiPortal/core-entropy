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

# Package as dynamic frameworks. CocoaPods refuses to vendor an xcframework
# of static libraries under Flutter's default pod linkage, and a dynamic
# framework is also what Dart's DynamicLibrary.open expects on iOS.
# Links one or more static archives into a dynamic framework. The simulator
# framework must be fat: Xcode builds simulator targets for both arm64 and
# x86_64, and a slice missing either arch is silently skipped by CocoaPods'
# copy phase, surfacing only as "Framework not found" at link time.
make_framework() {
  local name="$1" sdk="$2" min_target_suffix="$3"; shift 3
  local fw="$OUT/fw-$name/CoreEntropy.framework"
  local sysroot; sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  mkdir -p "$fw/Headers"

  local slices=()
  while [ "$#" -gt 0 ]; do
    local arch="$1" archive="$2"; shift 2
    local slice="$OUT/fw-$name/CoreEntropy-$arch.dylib"
    xcrun --sdk "$sdk" clang++ -dynamiclib \
      -target "$arch-apple-ios$MIN$min_target_suffix" -isysroot "$sysroot" \
      -install_name "@rpath/CoreEntropy.framework/CoreEntropy" \
      -Wl,-all_load "$archive" \
      -framework Foundation \
      -o "$slice"
    slices+=("$slice")
  done

  if [ "${#slices[@]}" -gt 1 ]; then
    lipo -create "${slices[@]}" -output "$fw/CoreEntropy"
  else
    cp "${slices[0]}" "$fw/CoreEntropy"
  fi

  cp src/core_entropy.h "$fw/Headers/"
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.satoshiportal.CoreEntropy</string>
  <key>CFBundleName</key><string>CoreEntropy</string>
  <key>CFBundleExecutable</key><string>CoreEntropy</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>MinimumOSVersion</key><string>$MIN</string>
</dict></plist>
PLIST
  printf '  %-22s %s\n' "framework $name" "$(lipo -archs "$fw/CoreEntropy")" >&2
  echo "$fw"
}

FW_DEV=$(make_framework device iphoneos "" arm64 "$DEV" | tail -1)
FW_SIM=$(make_framework simulator iphonesimulator "-simulator" \
           arm64 "$SIM_ARM" x86_64 "$SIM_X64" | tail -1)

rm -rf "$OUT/CoreEntropy.xcframework"
xcodebuild -create-xcframework \
  -framework "$FW_DEV" \
  -framework "$FW_SIM" \
  -output "$OUT/CoreEntropy.xcframework" >/dev/null

echo
fail=0
for lib in "$FW_DEV/CoreEntropy" "$FW_SIM/CoreEntropy"; do
  if strings "$lib" | grep -q '/dev/urandom'; then
    echo "  FAIL: /dev/urandom present in $(basename "$lib")"; fail=1
  fi
  if ! nm "$lib" 2>/dev/null | grep -q '_core_entropy_get_strong'; then
    echo "  FAIL: core_entropy_get_strong missing from $(basename "$lib")"; fail=1
  fi
  # -u lists imports; a dylib's undefined symbols do not appear in plain nm.
  if ! nm -u "$lib" 2>/dev/null | grep -q 'CCRandomGenerateBytes'; then
    echo "  FAIL: CCRandomGenerateBytes not imported by $(basename "$lib")"; fail=1
  fi
  # The shim must be the definition Core's getentropy() call binds to.
  if ! nm "$lib" 2>/dev/null | grep -qE '^[0-9a-f]+ T _getentropy$'; then
    echo "  FAIL: shim getentropy not defined in $(basename "$lib")"; fail=1
  fi
  # The reported source string must name the call that actually executes.
  # Shipping a binary that imports CCRandomGenerateBytes while telling the
  # user it used getentropy(2) is the kind of false diagnostic that gets
  # quoted in a security claim.
  if ! strings "$lib" | grep -qx 'CCRandomGenerateBytes'; then
    echo "  FAIL: reported OS source is not CCRandomGenerateBytes in $(basename "$lib")"; fail=1
  fi
  if strings "$lib" | grep -qx 'getentropy(2)'; then
    echo "  FAIL: iOS binary reports 'getentropy(2)', which does not exist on iOS"; fail=1
  fi
done

# Stage the verified artifact where the CocoaPods spec vendors it from. The
# plugin deliberately does not recompile the sources: that second build would
# bypass the checks below, which is the class of mistake this project exists
# to avoid.
PLUGIN_DIR="$ROOT/flutter/ios"
if [ -d "$PLUGIN_DIR" ]; then
  rm -rf "$PLUGIN_DIR/CoreEntropy.xcframework"
  cp -R "$OUT/CoreEntropy.xcframework" "$PLUGIN_DIR/"
  echo "  staged for Flutter: flutter/ios/CoreEntropy.xcframework"
fi

echo "  xcframework: $OUT/CoreEntropy.xcframework"
echo
[ "$fail" -eq 0 ] && echo "PASS: device + simulator built, no /dev/urandom, CCRandomGenerateBytes wired." \
                  || echo "FAIL"
exit $fail
