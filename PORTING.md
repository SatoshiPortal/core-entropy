# Porting Bitcoin Core's RNG to Android and iOS

A record of every change needed to take `core/random.cpp` — written for
desktop Bitcoin Core — and run it unmodified on Android and iOS, inside a
Flutter app.

The constraint throughout: **`core/` stays byte-identical to upstream v29.0**
(`make verify`, 56/56). Every platform problem is solved in `shim/`, in build
configuration, or in packaging. Nothing is patched into Core.

## Summary

| # | Problem | Where fixed |
|---|---|---|
| 1 | bionic gates `getrandom()` behind API 28 | `shim/android_getrandom.cpp` |
| 2 | iOS exports no `getentropy()`, ships no `<sys/random.h>` | `shim/sys/random.h`, `shim/apple_getentropy.cpp` |
| 3 | x86 pulled in an un-vendored SHA-256 assembly TU | `shim/bitcoin-build-config.h` |
| 4 | CocoaPods cannot glob sources outside the pod root | vendored framework |
| 5 | CocoaPods rejects a *static* xcframework under Flutter | dynamic framework |
| 6 | Simulator needs arm64 **and** x86_64 | `scripts/build_ios.sh` |
| 7 | `DynamicLibrary.process()` misused on iOS | `dart/lib/core_entropy.dart` |
| 8 | Objective-C symbol-retention shim broke the link | deleted |
| 9 | `nm` does not list a dylib's imports | `scripts/build_ios.sh` |

Nos. 1–3 are correctness. 4–9 are packaging. No. 3 is the one worth reading.

---

## 1. Android: bionic gates `getrandom()` behind API 28

Core's `GetOSRand()` calls `getrandom()` on the `HAVE_GETRANDOM` branch.
bionic declares it `__INTRODUCED_IN(28)`, so at API 26 the declaration is not
visible and the build fails:

```
core/random.cpp:379:9: error: use of undeclared identifier 'getrandom'
```

The syscall itself has existed since API 23. Raising the floor to 28 would
drop Android 8.x users; letting the branch go unselected would drop Core into
its `/dev/urandom` `#else`. Neither is acceptable.

`shim/bitcoin-build-config.h` declares the function for API < 28 — it is
included at `random.cpp:6`, before `<sys/random.h>` at line 38 — and
`shim/android_getrandom.cpp` defines it as a direct syscall:

```cpp
extern "C" ssize_t getrandom(void* buffer, size_t buffer_size, unsigned int flags)
{
    return static_cast<ssize_t>(syscall(__NR_getrandom, buffer, buffer_size, flags));
}
```

This is not a fallback. There is one code path; `ENOSYS` returns -1 and Core
aborts. Verified compiling at API 21, 24, 26, 28 and 34.

## 2. iOS exports no `getentropy()`

Core's Apple branch is macOS-shaped. It calls `getentropy()` and includes
`<sys/random.h>`. On the iOS SDK:

- `<sys/random.h>` does not exist.
- `getentropy()` is declared in no public header. The only trace is
  `#define SYS_getentropy 500` in `<sys/syscall.h>`.

Apple's public CSPRNG on iOS is CommonCrypto or Security.framework. Without a
fix, `HAVE_GETENTROPY_RAND` cannot be defined, and Core falls into the
`/dev/urandom` `#else` — silently, with a working-looking build.

Two shim files close it:

- `shim/sys/random.h` sits ahead of the SDK on the include path. On Apple
  mobile it declares `getentropy()`; everywhere else it chains through with
  `#include_next`.
- `shim/apple_getentropy.cpp` implements it over `CCRandomGenerateBytes` —
  public API, in libSystem so no extra framework link, and the same call the
  Rust `getrandom` crate makes on these targets. Any non-success becomes
  `-1`/`EIO`, so Core aborts.

`scripts/build_ios.sh` asserts on the built binary that
`_CCRandomGenerateBytes` is imported and `_getentropy` is defined by the shim.

## 3. x86 pulled in an un-vendored SHA-256 translation unit

The interesting one, because it is the same shape as the bug that cost
Coldcard users $38M in July 2026.

`shim/bitcoin-build-config.h` originally left `USE_SSE4`, `USE_AVX2`,
`USE_SHANI` and `ENABLE_ARM_SHANI` undefined, with a comment stating that
hardware SHA-256 paths were deliberately disabled. Host (arm64) and Android
arm builds were fine. Android **x86_64** failed to link:

```
ld.lld: error: undefined symbol: sha256_sse4::Transform(unsigned int*, unsigned char const*, unsigned long)
```

`core/crypto/sha256.cpp:27` declares that namespace behind a plain
architecture guard:

```cpp
#if defined(__x86_64__) || defined(__amd64__) || defined(__i386__)
namespace sha256_sse4 { void Transform(uint32_t*, const unsigned char*, size_t); }
#endif
```

No build-config macro is consulted. **The intent "no hardware paths" was
expressed in macros the code does not read.** The build config said one thing;
the code did another; and it only surfaced when a new architecture was added.

That is precisely Coldcard's failure mode. Their firmware had two RNG
implementations with identical signatures — the hardware TRNG and a
MicroPython software fallback — and a preprocessor guard that checked whether
a configuration setting was *defined* rather than whether its *value* was
correct. The build silently resolved to the software fallback with no warning.
The firmware produced valid addresses and accepted deposits for five years
while generating ~40-bit seeds.

The difference in outcome here is luck, not virtue: our wrong selection failed
to *link*, theirs linked fine. The fix is to use the switch the code actually
reads:

```c
#define DISABLE_OPTIMIZED_SHA256 1
```

One SHA-256 implementation on every target. Fewer conditional branches in the
build is fewer places for a selection bug to hide, and SHA-256 speed is
irrelevant to entropy quality.

The durable lesson is the one this project already applies to `/dev/urandom`:
**verify the artifact, not the intent.** Build-time assertions now run on
every produced binary — see below.

## 4. CocoaPods cannot glob sources outside the pod root

`s.source_files` with `../../core/**/*.cpp` collects nothing. CocoaPods
resolves globs with Ruby's `Dir.glob` at install time, and it will not reach
above the podspec's directory. Symlinking the directories into the plugin
(`flutter/src/core -> ../../core`) does not help either: `Dir.glob` does not
descend into symlinked directories.

Related but separate: `PODS_TARGET_SRCROOT` points through Flutter's
`.symlinks/plugins/<plugin>/ios` indirection, so `${PODS_TARGET_SRCROOT}/../..`
in `HEADER_SEARCH_PATHS` resolves *lexically* to `.symlinks/plugins/` — outside
the plugin entirely.

Rather than duplicate the source tree, the podspec vendors the artifact that
`scripts/build_ios.sh` already produces **and checks**. Recompiling the sources
inside CocoaPods would have produced a second binary that never passed those
assertions — exactly the unverified-artifact problem this project exists to
avoid. The podspec invokes the build script if the framework is missing.

## 5. Static xcframework rejected under Flutter's pod linkage

```
[!] Unable to install vendored xcframework `CoreEntropy` for Pod
    `core_entropy_flutter` because it contains static libraries
```

Flutter's default Podfile links pods dynamically. `build_ios.sh` now packages
the static archives into **dynamic** `CoreEntropy.framework` bundles
(`-install_name @rpath/CoreEntropy.framework/CoreEntropy`) before
`-create-xcframework`. This also matches what `DynamicLibrary.open` expects on
iOS.

## 6. The simulator slice must be fat

Building the simulator framework for `arm64-apple-ios-simulator` only produced
an arm64 binary. Xcode builds simulator targets for arm64 *and* x86_64, and
CocoaPods' copy phase skips a non-matching slice with a **warning**, not an
error:

```
warning: [CP] CoreEntropy.xcframework: Unable to find matching slice in
'ios-arm64 ios-arm64-simulator' for the current build architectures
(arm64 x86_64) and platform (-iphonesimulator).
```

which surfaces later as the unhelpful `Framework 'CoreEntropy' not found`.
`make_framework()` now links each arch separately and `lipo`s them.

## 7. `DynamicLibrary.process()` misused

The first iOS binding did:

```dart
if (Platform.isIOS) return DynamicLibrary.process().toString();
```

— stringifying a library handle and then trying to `open()` that string. With
the dynamic framework the correct form is a path:

```dart
if (Platform.isIOS) return 'CoreEntropy.framework/CoreEntropy';
```

## 8. The Objective-C symbol-retention shim

`ios/Classes/CoreEntropyPlugin.m` held `__attribute__((used))` references to
the C ABI so a *static* link would not dead-strip them. Once the framework
became dynamic its exports survive independently, and the file only introduced
undefined symbols at link time. Deleted. The plugin now contains no
Objective-C and no Swift.

## 9. `nm` does not list a dylib's imports

The `CCRandomGenerateBytes` assertion failed against a correct binary: plain
`nm` does not print undefined symbols for a dylib. Fixed to `nm -u`, and a
second check was added asserting the shim's `_getentropy` is defined (`T`).

A check that silently tests the wrong thing is worse than no check — it was
reporting FAIL here, but the same class of mistake reports PASS just as
easily.

---

## Why no Kotlin or Swift

Neither is needed, and neither would help.

This is a Flutter **FFI** plugin: Dart calls the C ABI directly. A Kotlin or
Swift layer could only marshal bytes between Dart and C, which adds a copy of
key material, another language boundary, and another place for a bug — for no
capability the C ABI lacks. The plugin ships zero lines of Kotlin, Swift, Java
or Objective-C, and that is a feature: the audit surface stays `shim/`, `src/`,
and the build files.

The one thing native code was used for — forcing symbol retention under static
linking — disappeared when the iOS artifact became a dynamic framework.

## Build-time assertions

Coldcard's firmware was a build that silently selected a weaker RNG and still
produced valid output. Intent is not verifiable; artifacts are. Every build
path now checks the binary it just produced:

| Where | Checks |
|---|---|
| `flutter/src/assert_no_fallback.cmake` (Gradle/CMake, every Flutter Android build) | no `/dev/urandom`; `core_entropy_get_strong` exported; Core's FAST path *not* exported |
| `scripts/build_android.sh` (all 4 ABIs) | no `/dev/urandom`; symbols exported |
| `scripts/build_ios.sh` (device + simulator) | no `/dev/urandom`; `CCRandomGenerateBytes` imported; shim `getentropy` defined |
| `scripts/provenance_test.sh` (host) | `#error` fires with no OS source selected; process aborts under fault injection; `GetDevURandom` stripped; only the strong generator exported |

## Verified state

| Target | OS source | Result |
|---|---|---|
| Android arm64 emulator (API 35) | `getrandom(2)` | 11/11 harness; Flutter app draws live |
| iOS simulator (iPhone 17 Pro) | `getentropy(2)` | 10/10 harness; Flutter app draws live |
| Android cross-compile | `getrandom(2)` | 4/4 ABIs, assertions pass |
| iOS cross-compile | `getentropy(2)` | device arm64 + simulator arm64/x86_64 |
| macOS host | `getentropy(2)` | 11/11 harness, 15/15 Dart, 4/4 provenance |
| `core/` provenance | — | 56/56 byte-identical to v29.0 |

Not yet done: physical hardware (emulator and simulator exercise the real OS
entropy path, but that is not the same claim), fault injection on Android and
iOS rather than host only, and `mlock` behaviour in `lockedpool.cpp` under the
iOS sandbox.
