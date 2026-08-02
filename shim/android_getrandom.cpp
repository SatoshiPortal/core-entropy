// Not a Bitcoin Core file.
//
// bionic gates getrandom() behind API 28 (__INTRODUCED_IN(28)) even though the
// underlying syscall landed in API 23 / Linux 3.17. Core's GetOSRand() calls
// getrandom() unconditionally on the HAVE_GETRANDOM branch, so without this
// the library would either not build below API 28 or would have to fall
// through to Core's /dev/urandom #else branch — which this project does not
// permit.
//
// Supplying the symbol here keeps core/random.cpp byte-identical and keeps the
// single-code-path property: this is getrandom(2) and nothing else. Every
// failure, including ENOSYS on a kernel too old to have the syscall, returns
// -1, which drives Core into RandFailure() -> std::abort().

#include <bitcoin-build-config.h>

#ifdef CORE_ENTROPY_ANDROID_GETRANDOM_SHIM

#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

extern "C" ssize_t getrandom(void* buffer, size_t buffer_size, unsigned int flags)
{
    return static_cast<ssize_t>(
        syscall(__NR_getrandom, buffer, buffer_size, flags));
}

#endif
