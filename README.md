# core-entropy

Bitcoin Core's RNG, extracted as a standalone C++ library with Dart FFI
bindings, configured to **panic rather than fall back**.

Prototype. Not wired into any product.

## Why

Bull Bitcoin Mobile currently derives wallet seeds from `bdk-ffi`'s
`Mnemonic::new`, which calls `rand::thread_rng()` — a userspace ChaCha12
CSPRNG seeded from the OS — under an upstream comment reading
`TODO 4: I DON'T KNOW IF THIS IS A DECENT WAY TO GENERATE ENTROPY PLEASE CONFIRM`.
This explores replacing that with the RNG from the most-reviewed codebase in
Bitcoin, on terms a Core developer can audit.

## Provenance

Everything under `core/` is **byte-identical to `bitcoin/bitcoin` v29.0**.
No edits, no patches, no reimplementations. Verify it yourself:

```
make verify
```

which re-downloads each file from the upstream tag and `cmp`s it. Current
state: **56/56 identical**. The entire non-Core surface is four files:

| File | Purpose |
|---|---|
| `shim/bitcoin-build-config.h` | Substitute for Core's build-generated header. **All project policy lives here.** |
| `shim/bitcoin-build-info.h` | Substitute for Core's git-metadata header. Intentionally empty. |
| `src/core_entropy.h` | C ABI declarations |
| `src/core_entropy.cpp` | C ABI implementation |

A reviewer needs to read those four files and nothing else.

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
correlation, runs. These are worth running, and they are **not entropy tests**.
The harness proves it by running the identical battery against ChaCha20 with an
all-zero key:

```
Tier 2 - statistical
  [T2] core monobit          PASS   z=-0.912
  [T2] core byte uniformity  PASS   chi2=245.3
  [T2] core shannon entropy  PASS   H=7.99932 bits/byte

Tier 2 - same battery, ChaCha20 with an all-zero key
  [T2] fixedkey monobit          PASS   z=-0.431
  [T2] fixedkey byte uniformity  PASS   chi2=265.4
  [T2] fixedkey shannon entropy  PASS   H=7.99927 bits/byte
```

A generator with *zero entropy* passes every one. Statistical tests measure a
PRNG's output function, never whether it was seeded. Anyone citing dieharder or
NIST SP 800-22 as evidence their wallet's entropy is sound has measured the
wrong thing.

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
make lib      # libcore_entropy.dylib / .so
make test     # C++ harness, tiers 1-2
make verify   # byte-identity against upstream v29.0
./scripts/provenance_test.sh   # tier 3

cd dart && dart pub get
CORE_ENTROPY_LIB=../build/libcore_entropy.dylib dart test
```

Host status: 16/16 C++, 15/15 Dart, 3/3 provenance, 56/56 byte-identity.

## Known gaps

- **Host-only so far.** No Android NDK or iOS cross-compile yet, and no
  Flutter plugin packaging. `HAVE_GETRANDOM` is selected for Android but has
  not been built or run there.
- **Not benchmarked.** `GetStrongRandBytes` does a full slow reseed per 32-byte
  chunk (`ProcRand` asserts `num <= 32`); cost on a phone is unmeasured.
- **Binary size unmeasured.** 56 Core files plus libc++ against the current
  `rand`-based path.
- **`randomenv.cpp` on Android** scrapes `/proc`, which SELinux restricts.
  Harmless — it only reduces salt, never entropy — but unverified in practice.
- **Reproducible builds.** Adding a C++ toolchain alongside the existing Rust
  pipeline has not been assessed against the repo's reproducibility work.

## License

MIT. `core/` is unmodified Bitcoin Core, redistributed under its original MIT
license with copyright retained; everything else is (c) 2026 Satoshi Portal Inc.
See [LICENSE](LICENSE).
