// Not a Bitcoin Core file. Bitcoin Core generates this header from its build
// system; everything under core/ is byte-identical to upstream v29.0 and this
// is the substitute for the generated artifact.
//
// The only policy this project imposes on Core's code lives here, in the
// macro selection below. Core's src/random.cpp is unmodified.

#ifndef BITCOIN_BUILD_CONFIG_H
#define BITCOIN_BUILD_CONFIG_H

// ---------------------------------------------------------------------------
// OS entropy source selection
//
// Core's GetOSRand() is an #if ladder. Every platform branch calls
// RandFailure() -> LogError + std::abort() when the source fails. The final
// #else branch is the only one that reads /dev/urandom.
//
// Defining exactly one platform macro below keeps us out of that #else. The
// static_assert at the bottom of this header fails the build if none is
// selected, so the fallback branch cannot be reached by accident or by a
// future toolchain change.
// ---------------------------------------------------------------------------

#if defined(__ANDROID__) || defined(__linux__)
  #define HAVE_GETRANDOM 1
  #define CORE_ENTROPY_OS_SOURCE "getrandom(2)"
  #define CORE_ENTROPY_SOURCE_SELECTED 1

  // bionic declares getrandom() with __INTRODUCED_IN(28), so Core's
  // HAVE_GETRANDOM branch does not compile below API 28 even though the
  // syscall has existed since API 23. Declaring it here (this header is
  // included at random.cpp:6, before <sys/random.h> at line 38) lets Core's
  // code compile untouched; shim/android_getrandom.cpp supplies the
  // definition as a direct syscall.
  //
  // This is not a fallback. There is one code path, it is getrandom(2), and
  // a failed syscall returns -1 so that Core calls RandFailure() -> abort().
  #if defined(__ANDROID__) && __ANDROID_API__ < 28
    #include <sys/types.h>
    #ifdef __cplusplus
extern "C"
    #endif
    ssize_t getrandom(void* __buffer, size_t __buffer_size, unsigned int __flags);
    #define CORE_ENTROPY_ANDROID_GETRANDOM_SHIM 1
  #endif
#elif defined(__APPLE__)
  #define HAVE_GETENTROPY_RAND 1
  #define HAVE_SYSCTL 1
  #define CORE_ENTROPY_SOURCE_SELECTED 1

  // CORE_ENTROPY_OS_SOURCE must name the call that actually executes, not the
  // Core branch that was selected. macOS really does have getentropy(2); iOS,
  // tvOS and watchOS do not, and there Core's getentropy() call binds to
  // shim/apple_getentropy.cpp, which is CCRandomGenerateBytes.
  //
  // Reporting "getentropy(2)" on iOS was a live falsehood in this file: the
  // string was set once for all of __APPLE__. A diagnostic that misnames the
  // entropy source is worse than no diagnostic, because it is quoted.
  #include <TargetConditionals.h>
  #if TARGET_OS_OSX
    #define CORE_ENTROPY_OS_SOURCE "getentropy(2)"
  #else
    #define CORE_ENTROPY_OS_SOURCE "CCRandomGenerateBytes"
    #define CORE_ENTROPY_EXPECT_CCRANDOM 1
  #endif
#else
  #define CORE_ENTROPY_SOURCE_SELECTED 0
#endif

// ---------------------------------------------------------------------------
// randomenv.cpp environment scraping
//
// These gate optional additional-entropy sources. None of them is relied upon
// for security: RandAddStaticEnv/RandAddDynamicEnv only mix extra material
// into the SHA-512 state on top of GetOSRand(). Missing sources reduce salt,
// never entropy.
// ---------------------------------------------------------------------------

#if defined(__APPLE__)
  #define HAVE_DECL_GETIFADDRS 1
  #define HAVE_DECL_FREEIFADDRS 1
#elif defined(__ANDROID__)
  // getifaddrs() exists in bionic from API 24. SELinux blocks much of the
  // /proc scraping on modern Android; that is expected and harmless.
  #if __ANDROID_API__ >= 24
    #define HAVE_DECL_GETIFADDRS 1
    #define HAVE_DECL_FREEIFADDRS 1
  #else
    #define HAVE_DECL_GETIFADDRS 0
    #define HAVE_DECL_FREEIFADDRS 0
  #endif
  #define HAVE_SYS_PRCTL_H 1
#else
  #define HAVE_DECL_GETIFADDRS 0
  #define HAVE_DECL_FREEIFADDRS 0
#endif

// ---------------------------------------------------------------------------
// SHA-256 implementation selection
//
// DISABLE_OPTIMIZED_SHA256 forces Core's portable C++ SHA-256 on every target.
//
// This is defined rather than left to the defaults for a specific reason. An
// earlier revision of this file simply left USE_SSE4 / USE_AVX2 / USE_SHANI /
// ENABLE_ARM_SHANI undefined and assumed that was enough. It was not: Core
// declares and instantiates sha256_sse4::Transform behind a plain
// `#if defined(__x86_64__) || defined(__amd64__) || defined(__i386__)`
// architecture guard, independent of any build-config macro. The intent
// "no hardware paths" was expressed in a macro the code does not consult, so
// x86 builds silently pulled in a translation unit that was never vendored,
// and the mistake only surfaced when a new architecture was added.
//
// That is the same shape as the failure that cost Coldcard users their funds
// in July 2026: a build-time guard that tested something adjacent to what the
// author believed it tested, producing a binary that looked correct. The
// lesson taken here is to use the switch the code actually reads, and to
// verify the resulting artifact rather than the intent.
//
// One SHA-256 path on every target: fewer conditional branches in the build
// is fewer places for a selection bug to hide. SHA-256 speed is irrelevant to
// entropy quality.
//
// HAVE_GETCPUID is x86-only and left undefined, which also disables Core's
// RDRAND/RDSEED seeding. That hardware does not exist on ARM anyway.
// ---------------------------------------------------------------------------

#define DISABLE_OPTIMIZED_SHA256 1

// ---------------------------------------------------------------------------
// Client version
//
// clientversion.h #errors without these. randomenv.cpp's only use is
// `hasher << CLIENT_VERSION` (randomenv.cpp:287), mixing a build identifier
// into the environment hash. The values are identifiers, not entropy, so they
// track the vendored Core tag rather than anything about this project.
// clientversion.cpp is vendored but not compiled: nothing we build calls
// FormatFullVersion() or LicenseInfo().
// ---------------------------------------------------------------------------

#define CLIENT_VERSION_MAJOR 29
#define CLIENT_VERSION_MINOR 0
#define CLIENT_VERSION_BUILD 0
#define CLIENT_VERSION_IS_RELEASE true
#define COPYRIGHT_YEAR 2025
#define COPYRIGHT_HOLDERS_FINAL "The Bitcoin Core developers"

#define CLIENT_VERSION_STRING "29.0.0"

// util/check.cpp embeds these in its assertion-failure message;
// clientversion.cpp uses the rest to build its version strings.
#define CLIENT_NAME "core-entropy"
#define CLIENT_BUGREPORT "https://github.com/SatoshiPortal/core-entropy/issues"
#define CLIENT_URL "https://github.com/SatoshiPortal/core-entropy"
#define COPYRIGHT_HOLDERS "The %s developers"
#define COPYRIGHT_HOLDERS_SUBSTITUTION "Bitcoin Core"

#if !CORE_ENTROPY_SOURCE_SELECTED
  #error "No OS entropy source selected. Core's GetOSRand() would fall through to its /dev/urandom #else branch, which this project does not permit. Add a platform branch above."
#endif

#endif // BITCOIN_BUILD_CONFIG_H
