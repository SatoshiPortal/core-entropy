// Not a Bitcoin Core file.
//
// core/random.cpp:36 includes <sys/random.h> on the
// `HAVE_GETRANDOM || (HAVE_GETENTROPY_RAND && __APPLE__)` branch. That include
// is macOS-shaped: the iOS, tvOS and watchOS SDKs ship no <sys/random.h> and
// do not declare getentropy() in any public header. Only the raw syscall
// number survives, in <sys/syscall.h>.
//
// This header sits ahead of the SDK on the include path so Core's include
// resolves. Everywhere a real <sys/random.h> exists it chains straight to it;
// on Apple's mobile platforms it declares getentropy(), which
// shim/apple_getentropy.cpp implements over CCRandomGenerateBytes — Apple's
// public CSPRNG on those platforms, and the same call the Rust getrandom
// crate makes there.
//
// Core's source is untouched either way.

#ifndef CORE_ENTROPY_SHIM_SYS_RANDOM_H
#define CORE_ENTROPY_SHIM_SYS_RANDOM_H

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && !TARGET_OS_OSX

#include <sys/types.h>

#define CORE_ENTROPY_APPLE_GETENTROPY_SHIM 1

#ifdef __cplusplus
extern "C" {
#endif

// Contract matches POSIX getentropy(3): 0 on success, -1 with errno set on
// failure. Core treats any non-zero return as fatal (RandFailure -> abort),
// so there is no path here that degrades to a weaker source.
int getentropy(void* __buffer, size_t __size);

#ifdef __cplusplus
}
#endif

#else

#include_next <sys/random.h>

#endif

#endif // CORE_ENTROPY_SHIM_SYS_RANDOM_H
