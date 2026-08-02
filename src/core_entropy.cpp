// C ABI over Bitcoin Core's RNG. Not a Bitcoin Core file.
//
// Everything under core/ is byte-identical to bitcoin/bitcoin v29.0. This
// translation unit and shim/ are the only non-Core code in the library.

#include "core_entropy.h"

#include <bitcoin-build-config.h>

#include <random.h>
#include <span.h>
#include <util/translation.h>
#include <crypto/sha512.h>
#include <support/cleanse.h>

#include <cstddef>

// util/translation.h declares this extern; Core defines it per-binary
// (bitcoind wires up a real translator, bitcoin-tx and friends use nullptr).
// A library has no UI to translate, so nullptr it is. Reached only from
// clientversion.cpp's LicenseInfo()/CopyrightHolders(), which nothing in this
// library calls; it exists to satisfy the linker.
const TranslateFn G_TRANSLATION_FUN{nullptr};

extern "C" {

namespace {
constexpr size_t kMaxPerCall = 32; // ProcRand asserts num <= 32
}

void core_entropy_get_strong(uint8_t* out, size_t len)
{
    for (size_t off = 0; off < len; off += kMaxPerCall) {
        const size_t n = (len - off) < kMaxPerCall ? (len - off) : kMaxPerCall;
        GetStrongRandBytes(Span<unsigned char>{out + off, n});
    }
}

void core_entropy_add_entropy(const uint8_t* data, size_t len)
{
    if (len == 0) return;

    unsigned char digest[CSHA512::OUTPUT_SIZE];
    CSHA512().Write(data, len).Finalize(digest);

    for (size_t off = 0; off < sizeof(digest); off += 4) {
        uint32_t word = 0;
        for (size_t i = 0; i < 4; i++) {
            word |= static_cast<uint32_t>(digest[off + i]) << (8 * i);
        }
        RandAddEvent(word);
    }
    memory_cleanse(digest, sizeof(digest));
}

void core_entropy_add_event(uint32_t event_info)
{
    RandAddEvent(event_info);
}

void core_entropy_reseed(void)
{
    RandAddPeriodic();
}

int core_entropy_sanity_check(void)
{
    return Random_SanityCheck() ? 1 : 0;
}

const char* core_entropy_os_source(void)
{
    return CORE_ENTROPY_OS_SOURCE;
}

size_t core_entropy_os_block_size(void)
{
    // Mirrors NUM_OS_RANDOM_BYTES (random.cpp:55), which is file-static and
    // absent from random.h, so it cannot be read from here. Duplicated, and
    // it will go stale silently if upstream changes it.
    //
    // The staleness is contained rather than detected: kMaxPerCall above is
    // the value that actually governs chunking, and if Core ever lowered its
    // limit, ProcRand's `assert(num <= 32)` would abort loudly on the first
    // call. This accessor is informational only — nothing in the library
    // branches on it.
    return 32;
}

} // extern "C"
