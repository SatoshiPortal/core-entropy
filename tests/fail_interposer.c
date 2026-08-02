/* Preloaded shim that makes the OS entropy syscall fail, so the "panic, never
 * fall back" contract is tested rather than asserted.
 *
 * If a /dev/urandom fallback were reachable in Core's GetOSRand(), the harness
 * would survive this and print entropy. It must instead die on SIGABRT from
 * RandFailure(). This is the only test that distinguishes "no fallback" from
 * "a fallback we believe is unreachable".
 *
 * macOS binds libSystem symbols in a two-level namespace, so plain symbol
 * shadowing does not interpose; the __DATA,__interpose section is the
 * supported mechanism. On Linux/Android, LD_PRELOAD shadowing works. */

#include <errno.h>
#include <stddef.h>
#include <sys/types.h>

#ifdef __APPLE__

extern int getentropy(void*, size_t);

static int fail_getentropy(void* buf, size_t len)
{
    (void)buf;
    (void)len;
    errno = EIO;
    return -1;
}

__attribute__((used)) static struct {
    const void* replacement;
    const void* replacee;
} _interpose_getentropy __attribute__((section("__DATA,__interpose"))) = {
    (const void*)&fail_getentropy,
    (const void*)&getentropy,
};

#else

int getentropy(void* buf, size_t len)
{
    (void)buf;
    (void)len;
    errno = EIO;
    return -1;
}

ssize_t getrandom(void* buf, size_t len, unsigned int flags)
{
    (void)buf;
    (void)len;
    (void)flags;
    errno = ENOSYS;
    return -1;
}

#endif
