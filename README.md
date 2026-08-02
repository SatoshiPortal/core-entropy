# core-entropy

Bitcoin Core's RNG, extracted as a standalone C++ library with Dart FFI
bindings.

Prototype.

## Why

Entropy is the foundation of Bitcoin key security. Every private key, every
address, every signature derives from a single initial draw — and unlike most
cryptographic failures, a weak one is invisible. The keys look correct, the
wallet works, and the funds are gone whenever someone else notices.

Bitcoin Core's RNG is the most reviewed code of its kind in the ecosystem.
Reusing it means inheriting that review rather than re-litigating the same
decisions in yet another implementation. That only works if the code is
genuinely the same code, which is why `core/` is vendored byte-identical and
machine-verifiable rather than adapted, ported, or reimplemented — a
reimplementation inherits none of the scrutiny that made the original worth
reusing.

This is not specific to any wallet. Any project that needs entropy it can
defend should be able to take it.

## Provenance

Everything under `core/` is **byte-identical to `bitcoin/bitcoin` v29.0**.
No edits, no patches, no reimplementations. Verify it yourself:

```
make verify
```

which re-downloads each file from the upstream tag and `cmp`s it. Current
state: **56/56 identical**. The entire non-Core surface is seven files:

| File | Purpose |
|---|---|
| `shim/bitcoin-build-config.h` | Substitute for Core's build-generated header. **All project policy lives here.** |
| `shim/bitcoin-build-info.h` | Substitute for Core's git-metadata header. Intentionally empty. |
| `shim/android_getrandom.cpp` | Supplies `getrandom()` below Android API 28 |
| `shim/sys/random.h` | Satisfies Core's include on Apple mobile SDKs |
| `shim/apple_getentropy.cpp` | Supplies `getentropy()` on iOS |
| `src/core_entropy.h` | C ABI declarations |
| `src/core_entropy.cpp` | C ABI implementation |

A reviewer needs to read those seven files and nothing else. `make verify`
prints the list, so it cannot drift from reality unnoticed.

## No fallback

Core's `GetOSRand()` (`core/random.cpp`) is an `#if` ladder. Every platform
branch calls `RandFailure()` → `LogError` + `std::abort()`. The `/dev/urandom`
read is only the final `#else`, reached when no platform macro is defined.

So this required **zero changes to Core's code** — only a build config that
guarantees we never land in `#else`:

- Android/Linux → `HAVE_GETRANDOM` → `getrandom(2)`, abort on failure
- iOS/macOS → `HAVE_GETENTROPY_RAND` → `getentropy(2)`, abort on failure
- neither → `#error` at compile time

The `#error` is the load-bearing part: the fallback branch cannot be reached
by accident, by a new target, or by a toolchain change. It fails the build
instead.

`-ffunction-sections` + dead-stripping then removes `GetDevURandom()` from the
shared library entirely, so the claim is checkable on the shipped artifact
rather than argued from source.

## Contributing your own entropy

Supported, and safe with arbitrary input quality. Core's `RNGState::MixExtract`
folds new material into the persistent 32-byte state through SHA-512 and never
replaces it; `AddEvent` accumulates into a chained SHA-256 folded in at every
reseed (`core/random.cpp:444-471`). A contribution therefore **cannot weaken
the pool**, however bad it is. That is what makes it safe to accept camera
frames, touch timings, or dice from a user.

The C ABI exposes exactly two ways in, and nothing that interprets them:

| | Use for | Mechanism |
|---|---|---|
| `core_entropy_add_event(uint32)` | one tap, swipe sample, die face | one `RandAddEvent` |
| `core_entropy_add_entropy(buf, len)` | camera frame, sensor buffer | SHA-512 → 16 `RandAddEvent` |

Prefer `add_event` for streams. Core mixes a fresh performance counter
alongside every call (`random.cpp:451`), and that sub-microsecond arrival
timing is usually worth more than the value itself — 100 taps fed one at a
time capture 100 timestamps; batched into one blob they capture 16.

### Layering

Deciding how a swipe becomes a `uint32` is an application concern, so it lives
in `dart/lib/collectors.dart`, not in the C++ library. `PointerEntropyCollector`,
`DiceEntropyCollector`, and `CameraEntropyCollector` are ordinary Dart built on
the two calls above. The C++ side stays small enough to review.

```dart
final pointer = PointerEntropyCollector(rng);
Listener(onPointerMove: (e) => pointer.sample(e.position.dx, e.position.dy));
pointer.commit();

final seed = rng.strongBytes(16);
```

**None of it is load-bearing.** The pool is already seeded from the OS CSPRNG
before any collector runs. Contributions are defence in depth against a
compromised OS RNG — they are not a source you can put a number on without a
real min-entropy assessment (NIST SP 800-90B). `DiceEntropyCollector` reports
an `entropyBitsUpperBound` for progress UI; it is an upper bound on a fair,
honestly-entered roll, not a measurement.

## Testing entropy

You cannot test that a value is random — randomness is a property of the
process, not the output. Tests are tiered by what they can actually detect.

**Tier 1 — catastrophic.** All-zero/all-ones output, sentinel-fill to catch
short writes, 20k draws all distinct, and **distinct across fresh processes**.
Cheap, and the only tier that would have caught Debian OpenSSL 2008 or Android
`SecureRandom` 2013. The cross-process test is the one that matters: "every
install generates the same seed" is invisible inside a single process.

**Tier 2 — statistical.** Monobit, byte chi-square, Shannon entropy, serial
correlation, runs. Worth running, and **not entropy tests**. Any CSPRNG passes
this battery whether or not it was ever seeded — the statistics describe the
output function, not the seed. A generator with a hardcoded key would score
identically to this one.

This repository does not ship a weak generator to demonstrate that, not even
as a teaching aid: nothing here produces entropy that is not strong, so there
is nothing to copy by mistake or to survive into a build. The consequence is
what matters, and it is short — citing dieharder, PractRand or NIST SP 800-22
as evidence that a wallet's entropy is sound is measuring the wrong thing.

**Tier 3 — provenance.** The only tier that tests what a security claim
actually claims. `scripts/provenance_test.sh` interposes the entropy syscall,
forces it to fail, and requires SIGABRT:

```
  [T3] baseline succeeds                 PASS
  [T3] aborts when OS source fails       PASS   SIGABRT from RandFailure()
  [T3] no /dev/urandom string in binary  PASS   GetDevURandom stripped
```

A build with a reachable fallback exits 0 here.

## Build

```
make lib                        # host shared library
make test                       # C++ harness, tiers 1-2
make verify                     # byte-identity against upstream v29.0
./scripts/provenance_test.sh    # tier 3

./scripts/build_android.sh [API]   # 4 ABIs -> build/android/<abi>/libcore_entropy.so
./scripts/build_ios.sh [MIN_IOS]   # device + simulator -> CoreEntropy.xcframework

./scripts/run_device_tests.sh all  # run the harness on a real emulator/simulator

cd dart && dart pub get
CORE_ENTROPY_LIB=../build/libcore_entropy.dylib dart test
```

### Platform support

| Target | OS source | Notes |
|---|---|---|
| Android arm64-v8a, armeabi-v7a, x86_64, x86 | `getrandom(2)` | API 21+ |
| iOS arm64 device + simulator | `getentropy(2)` | over `CCRandomGenerateBytes` |
| macOS / Linux host | `getentropy(2)` / `getrandom(2)` | for development |

Two platform gaps had to be closed without touching Core, both in `shim/`:

- **Android below API 28.** bionic declares `getrandom()` with
  `__INTRODUCED_IN(28)` although the syscall has existed since API 23, so
  Core's branch would not compile. `shim/android_getrandom.cpp` supplies the
  symbol as a direct `syscall(__NR_getrandom, ...)`. One code path, still no
  fallback — `ENOSYS` returns -1 and Core aborts.
- **iOS has no `getentropy()`.** The mobile SDKs ship no `<sys/random.h>` and
  declare `getentropy()` nowhere; Core's Apple branch is macOS-shaped.
  `shim/sys/random.h` satisfies the include and `shim/apple_getentropy.cpp`
  implements the function over `CCRandomGenerateBytes`, Apple's public CSPRNG
  on those platforms. Any non-success status becomes -1 and Core aborts.

### Status

| | |
|---|---|
| macOS host | 11/11 harness, 15/15 Dart, 3/3 provenance |
| Android arm64 (emulator, API 35) | 11/11 harness, `getrandom(2)` selected |
| iOS simulator (iPhone 17 Pro) | 11/11 harness, `getentropy(2)` selected |
| Cross-compile | 4/4 Android ABIs, iOS device + simulator |
| Provenance | 56/56 byte-identical to v29.0 |

## Known gaps

- **No Flutter plugin packaging.** The Android `.so` files and the iOS
  `.xcframework` are built and tested, but not yet wrapped as a pub package
  with the platform folders Flutter expects.
- **Not run on physical hardware.** Android results are from an emulator and
  iOS from the simulator. Both are the real OS entropy path, but a device pass
  is not the same claim.
- **Not benchmarked.** `GetStrongRandBytes` does a full slow reseed per 32-byte
  chunk (`ProcRand` asserts `num <= 32`); cost on a phone is unmeasured.
- **`mlock` under `lockedpool.cpp`** is unverified on iOS, where the sandbox
  may refuse it.
- **Binary size unmeasured.** 56 Core files plus libc++ against the current
  `rand`-based path.
- **Reproducible builds.** Adding a C++ toolchain alongside the existing Rust
  pipeline has not been assessed against the repo's reproducibility work.

## License

MIT. `core/` is unmodified Bitcoin Core, redistributed under its original MIT
license with copyright retained; everything else is (c) 2026 Satoshi Portal Inc.
See [LICENSE](LICENSE).
