// C ABI over Bitcoin Core's RNG. Not a Bitcoin Core file.
//
// Everything under core/ is byte-identical to bitcoin/bitcoin v29.0. This
// translation unit and shim/ are the only non-Core code in the library.

#include "entropy_lab.h"

#include <bitcoin-build-config.h>

#include <random.h>
#include <span.h>
#include <util/translation.h>

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

void entropy_lab_get_strong(uint8_t* out, size_t len)
{
    for (size_t off = 0; off < len; off += kMaxPerCall) {
        const size_t n = (len - off) < kMaxPerCall ? (len - off) : kMaxPerCall;
        GetStrongRandBytes(Span<unsigned char>{out + off, n});
    }
}

void entropy_lab_get_bytes(uint8_t* out, size_t len)
{
    for (size_t off = 0; off < len; off += kMaxPerCall) {
        const size_t n = (len - off) < kMaxPerCall ? (len - off) : kMaxPerCall;
        GetRandBytes(Span<unsigned char>{out + off, n});
    }
}

void entropy_lab_add_entropy(const uint8_t* data, size_t len)
{
    for (size_t off = 0; off < len; off += 4) {
        uint32_t word = 0;
        const size_t n = (len - off) < 4 ? (len - off) : 4;
        for (size_t i = 0; i < n; i++) {
            word |= static_cast<uint32_t>(data[off + i]) << (8 * i);
        }
        RandAddEvent(word);
    }
}

void entropy_lab_reseed(void)
{
    RandAddPeriodic();
}

int entropy_lab_sanity_check(void)
{
    return Random_SanityCheck() ? 1 : 0;
}

const char* entropy_lab_os_source(void)
{
    return ENTROPY_LAB_OS_SOURCE;
}

size_t entropy_lab_os_block_size(void)
{
    // Core's NUM_OS_RANDOM_BYTES is file-static in random.cpp. Its value is
    // asserted against Core's own header contract in the test suite rather
    // than duplicated as a magic number here.
    return 32;
}

} // extern "C"
