#!/usr/bin/env bash
# Run the entropy harness on real Android and iOS runtimes.
#
#   ./scripts/run_device_tests.sh [android|ios|all]
#
# Building for a platform proves the code compiles. This proves the selected
# syscall actually returns entropy there, which is the claim that matters.
#
# Cross-process distinctness is driven from here rather than from inside the
# harness: sandboxed mobile runtimes do not let a process re-spawn itself, so
# the host does the spawning.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WHICH="${1:-all}"
SPAWNS="${SPAWNS:-10}"
fail=0

banner() { echo; echo "=== $1 ==="; }

distinct_check() {
  local label="$1"; shift
  local seen
  seen=$(for _ in $(seq "$SPAWNS"); do "$@" 2>/dev/null | tr -d '\r\n'; echo; done | sort -u | grep -c .)
  if [ "$seen" -eq "$SPAWNS" ]; then
    printf '  [T1] %-38s PASS   %s distinct / %s fresh processes\n' \
      "distinct across process restarts" "$seen" "$SPAWNS"
  else
    printf '  [T1] %-38s FAIL   %s distinct / %s fresh processes\n' \
      "distinct across process restarts" "$seen" "$SPAWNS"
    fail=1
  fi
  echo "         ($label)"
}

run_android() {
  banner "Android"
  export PATH="$PATH:${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools"
  adb get-state >/dev/null 2>&1 || { echo "  no device/emulator; skipping"; return 0; }

  local abi ndk tc triple api=21
  abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')
  echo "  device ABI: $abi  (android-$(adb shell getprop ro.build.version.sdk | tr -d '\r'))"

  ndk="${ANDROID_NDK_HOME:-$(ls -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/ndk/* | sort -V | tail -1)}"
  tc="$ndk/toolchains/llvm/prebuilt/$(uname -s | tr 'A-Z' 'a-z')-x86_64/bin"
  case "$abi" in
    arm64-v8a)   triple=aarch64-linux-android ;;
    armeabi-v7a) triple=armv7a-linux-androideabi ;;
    x86_64)      triple=x86_64-linux-android ;;
    x86)         triple=i686-linux-android ;;
    *) echo "  unknown ABI $abi"; fail=1; return 1 ;;
  esac

  mkdir -p build/androidtest
  "$tc/${triple}${api}-clang++" -std=c++20 -O2 -static-libstdc++ \
    -Wno-unused-function -Ishim -Icore -Isrc \
    $(make -s print-sources) tests/harness.cpp -o build/androidtest/harness || { fail=1; return 1; }

  adb push -q build/androidtest/harness /data/local/tmp/core_entropy_harness >/dev/null 2>&1 \
    || adb push build/androidtest/harness /data/local/tmp/core_entropy_harness >/dev/null
  adb shell chmod 755 /data/local/tmp/core_entropy_harness

  adb shell /data/local/tmp/core_entropy_harness 2>&1 | sed 's/\r$//' | sed 's/^/  /'
  distinct_check "adb shell, $SPAWNS separate invocations" \
    adb shell /data/local/tmp/core_entropy_harness --emit
}

run_ios() {
  banner "iOS simulator"
  local dev sdk
  dev=$(xcrun simctl list devices booted | grep -oE '\(([0-9A-F-]{36})\)' | head -1 | tr -d '()')
  [ -n "$dev" ] || { echo "  no booted simulator; skipping"; return 0; }
  echo "  device: $dev"

  sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
  mkdir -p build/iossim
  xcrun --sdk iphonesimulator clang++ -std=c++20 -O2 \
    -target "$(uname -m)-apple-ios13.0-simulator" -isysroot "$sdk" \
    -Wno-unused-function -Ishim -Icore -Isrc \
    $(make -s print-sources) tests/harness.cpp -o build/iossim/harness || { fail=1; return 1; }

  xcrun simctl spawn "$dev" "$PWD/build/iossim/harness" 2>/dev/null | sed 's/^/  /'
  distinct_check "simctl spawn, $SPAWNS separate processes" \
    xcrun simctl spawn "$dev" "$PWD/build/iossim/harness" --emit
}

case "$WHICH" in
  android) run_android ;;
  ios)     run_ios ;;
  all)     run_android; run_ios ;;
  *) echo "usage: $0 [android|ios|all]"; exit 1 ;;
esac

echo
[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit $fail
