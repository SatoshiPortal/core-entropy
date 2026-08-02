// C ABI over Bitcoin Core's RNG. Not a Bitcoin Core file.

#ifndef ENTROPY_LAB_H
#define ENTROPY_LAB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Fill `out` with `len` bytes from Core's GetStrongRandBytes().
//
// There is no error return. Core's GetOSRand() calls RandFailure() ->
// std::abort() if the OS source fails, and this build is configured so that
// no /dev/urandom fallback branch is reachable. A caller that returns from
// this function has full-strength entropy in `out`; a caller that does not
// return has crashed the process. That is the intended contract.
//
// Core asserts num <= 32 in ProcRand (random.cpp:642), so larger requests are
// issued here as successive 32-byte draws, each with its own SLOW reseed.
void entropy_lab_get_strong(uint8_t* out, size_t len);

// Fill `out` from Core's GetRandBytes() (fast path, no slow reseeding).
// Same 32-byte chunking as above.
void entropy_lab_get_bytes(uint8_t* out, size_t len);

// ---------------------------------------------------------------------------
// Additional entropy input
//
// Core's RNG state is additive: RNGState::MixExtract folds new material into
// the persistent 32-byte state through SHA-512 and never replaces it, and
// AddEvent accumulates into a chained SHA-256 that is folded in at every
// reseed (random.cpp:444-471). Contributed entropy therefore cannot weaken
// the pool, no matter how bad it is. That is what makes it safe to accept
// dice rolls, touch timings, camera noise, or anything else from a caller.
//
// Granularity caveat: Core's only public input is RandAddEvent(uint32_t), so
// `len` bytes go in as ceil(len/4) events. Trailing bytes are zero-padded
// into the final word. This is faithful to upstream; a bulk-mix entry point
// would require patching random.cpp, which this project does not do.
//
// This does NOT block or reseed by itself. Call entropy_lab_reseed() when you
// want the contributed material folded into the extractable state.
void entropy_lab_add_entropy(const uint8_t* data, size_t len);

// Core's RandAddPeriodic(): folds accumulated events, OS entropy, the dynamic
// environment, and a CPU-bound strengthen loop into the state.
void entropy_lab_reseed(void);

// Core's Random_SanityCheck(). Returns 1 on pass, 0 on fail.
int entropy_lab_sanity_check(void);

// Name of the OS syscall this binary was compiled against, e.g. "getrandom(2)".
// Reflects the branch selected in shim/bitcoin-build-config.h.
const char* entropy_lab_os_source(void);

// Number of bytes Core's GetOSRand() draws per call (NUM_OS_RANDOM_BYTES).
size_t entropy_lab_os_block_size(void);

#ifdef __cplusplus
}
#endif

#endif // ENTROPY_LAB_H
