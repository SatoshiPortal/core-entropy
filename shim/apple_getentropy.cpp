// Not a Bitcoin Core file.
//
// Supplies getentropy() on Apple platforms that do not export it (iOS, tvOS,
// watchOS), so core/random.cpp's HAVE_GETENTROPY_RAND branch compiles and
// links unmodified.
//
// Backed by CCRandomGenerateBytes: public API, part of libSystem so no extra
// framework link, and documented by Apple as cryptographically secure. It is
// the same call the Rust getrandom crate makes on these targets.
//
// Single code path, no fallback. Any non-success status becomes -1/EIO, which
// drives Core into RandFailure() -> std::abort().

#include <sys/random.h>

#ifdef CORE_ENTROPY_APPLE_GETENTROPY_SHIM

#include <CommonCrypto/CommonRandom.h>
#include <errno.h>
#include <sys/types.h>

extern "C" int getentropy(void* buffer, size_t size)
{
    // POSIX getentropy(3) caps at 256 bytes and callers rely on that erroring
    // rather than short-filling. Core only ever asks for 32.
    if (size > 256) {
        errno = EIO;
        return -1;
    }
    if (CCRandomGenerateBytes(buffer, size) != kCCSuccess) {
        errno = EIO;
        return -1;
    }
    return 0;
}

#endif
