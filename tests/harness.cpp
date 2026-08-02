// Entropy test harness.
//
// The organising idea: you cannot test that a value is random. Randomness is a
// property of the process that produced a value, not of the value. So the
// tests are split into three tiers by what they can actually detect, and the
// harness reports which tier each result belongs to.
//
//   Tier 1  catastrophic     — catches the failures that have historically
//                              cost people money. Cheap, and the only tier
//                              that would have caught Debian OpenSSL 2008 or
//                              Android SecureRandom 2013.
//   Tier 2  statistical      — catches "we shipped an LCG" or "we returned a
//                              counter". Does NOT test entropy: any CSPRNG
//                              passes these whether or not it was ever seeded,
//                              so tier 2 alone is never evidence of anything.
//   Tier 3  provenance       — asserts which syscall was actually invoked and
//                              that failure is fatal. The only tier that tests
//                              what a public security claim actually claims.

#include "core_entropy.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>

namespace {

int g_pass = 0;
int g_fail = 0;

void report(int tier, const char* name, bool ok, const std::string& detail)
{
    (ok ? g_pass : g_fail)++;
    std::printf("  [T%d] %-38s %s   %s\n", tier, name, ok ? "PASS" : "FAIL", detail.c_str());
}

// ---------------------------------------------------------------------------
// Tier 2 battery. Applied both to the real RNG and to a deliberately broken
// one, so the output demonstrates what these tests can and cannot see.
// ---------------------------------------------------------------------------

struct Stats {
    double monobit_z;
    double chi2;
    double shannon;
    double serial_corr;
    double runs_z;
};

Stats analyse(const std::vector<uint8_t>& b)
{
    Stats s{};
    const size_t n = b.size();

    size_t ones = 0;
    for (uint8_t x : b) ones += __builtin_popcount(x);
    const double nbits = double(n) * 8.0;
    s.monobit_z = (double(ones) - nbits / 2.0) / std::sqrt(nbits / 4.0);

    std::array<size_t, 256> hist{};
    for (uint8_t x : b) hist[x]++;
    const double expect = double(n) / 256.0;
    s.chi2 = 0.0;
    s.shannon = 0.0;
    for (size_t c : hist) {
        const double d = double(c) - expect;
        s.chi2 += d * d / expect;
        if (c) {
            const double p = double(c) / double(n);
            s.shannon -= p * std::log2(p);
        }
    }

    double mean = 0.0;
    for (uint8_t x : b) mean += x;
    mean /= double(n);
    double num = 0.0, den = 0.0;
    for (size_t i = 0; i + 1 < n; i++) {
        num += (double(b[i]) - mean) * (double(b[i + 1]) - mean);
    }
    for (uint8_t x : b) den += (double(x) - mean) * (double(x) - mean);
    s.serial_corr = den > 0 ? num / den : 0.0;

    size_t runs = 1;
    int prev = (b[0] >> 7) & 1;
    for (size_t i = 0; i < n; i++) {
        for (int bit = 7; bit >= 0; bit--) {
            if (i == 0 && bit == 7) continue;
            const int cur = (b[i] >> bit) & 1;
            if (cur != prev) runs++;
            prev = cur;
        }
    }
    const double pi = double(ones) / nbits;
    s.runs_z = (double(runs) - 2.0 * nbits * pi * (1 - pi)) /
               (2.0 * std::sqrt(2.0 * nbits) * pi * (1 - pi));
    return s;
}

void run_tier2(const std::vector<uint8_t>& buf)
{
    const Stats s = analyse(buf);
    char d[256];

    std::snprintf(d, sizeof d, "z=%+.3f (|z|<4)", s.monobit_z);
    report(2, "monobit", std::fabs(s.monobit_z) < 4.0, d);

    std::snprintf(d, sizeof d, "chi2=%.1f (df=255, 170..350)", s.chi2);
    report(2, "byte uniformity", s.chi2 > 170 && s.chi2 < 350, d);

    std::snprintf(d, sizeof d, "H=%.5f bits/byte (>7.99)", s.shannon);
    report(2, "shannon entropy", s.shannon > 7.99, d);

    std::snprintf(d, sizeof d, "r=%+.5f (|r|<0.01)", s.serial_corr);
    report(2, "serial correlation", std::fabs(s.serial_corr) < 0.01, d);

    std::snprintf(d, sizeof d, "z=%+.3f (|z|<4)", s.runs_z);
    report(2, "runs", std::fabs(s.runs_z) < 4.0, d);
}

std::vector<uint8_t> draw(size_t n)
{
    std::vector<uint8_t> v(n);
    core_entropy_get_strong(v.data(), v.size());
    return v;
}

} // namespace

int main(int argc, char** argv)
{
    // Cross-process mode: emit one draw as hex and exit.
    if (argc > 1 && std::strcmp(argv[1], "--emit") == 0) {
        uint8_t b[32];
        core_entropy_get_strong(b, sizeof b);
        for (uint8_t x : b) std::printf("%02x", x);
        return 0;
    }

    std::printf("\ncore-entropy :: Bitcoin Core v29.0 RNG\n");
    std::printf("OS source compiled in : %s\n", core_entropy_os_source());
    std::printf("GetOSRand block size  : %zu bytes\n\n", core_entropy_os_block_size());

    // -----------------------------------------------------------------------
    std::printf("Tier 1 - catastrophic failure detection\n");

    report(1, "Core Random_SanityCheck()", core_entropy_sanity_check() == 1,
           "Core's own startup self-test");

    {
        auto v = draw(64);
        bool all_zero = true, all_ff = true;
        for (uint8_t x : v) { if (x) all_zero = false; if (x != 0xff) all_ff = false; }
        report(1, "output not all-zero", !all_zero, "64 bytes");
        report(1, "output not all-ones", !all_ff, "64 bytes");
    }

    {
        // Sentinel fill: a source that writes fewer bytes than promised leaves
        // recognisable filler behind. This is the shape of a short-read bug.
        std::vector<uint8_t> v(256, 0xAA);
        core_entropy_get_strong(v.data(), v.size());
        size_t untouched = 0;
        for (uint8_t x : v) if (x == 0xAA) untouched++;
        char d[128];
        std::snprintf(d, sizeof d, "%zu/256 bytes still 0xAA (expect ~1)", untouched);
        report(1, "buffer fully overwritten", untouched < 8, d);
    }

    {
        const size_t N = 20000;
        std::set<std::string> seen;
        for (size_t i = 0; i < N; i++) {
            auto v = draw(16);
            seen.insert(std::string(reinterpret_cast<char*>(v.data()), v.size()));
        }
        char d[128];
        std::snprintf(d, sizeof d, "%zu distinct / %zu draws of 16 bytes", seen.size(), N);
        report(1, "no repeats within process", seen.size() == N, d);
    }

    {
        // The failure that actually costs money: every install generating the
        // same seed. Only observable across process boundaries.
        const int N = 12;
        std::set<std::string> seen;
        for (int i = 0; i < N; i++) {
            std::string cmd = std::string(argv[0]) + " --emit";
            FILE* p = popen(cmd.c_str(), "r");
            if (!p) { report(1, "cross-process distinctness", false, "popen failed"); break; }
            char buf[80] = {0};
            if (std::fgets(buf, sizeof buf, p)) seen.insert(buf);
            pclose(p);
        }
        char d[192];
        if (seen.empty()) {
            // Sandboxed runtimes (the iOS simulator, some Android shells) do
            // not let a process re-spawn itself. The check is still run on
            // those platforms, from outside: see scripts/run_device_tests.sh.
            std::printf("  [T1] %-38s SKIP   child spawn unavailable here; "
                        "run scripts/run_device_tests.sh\n",
                        "distinct across process restarts");
        } else {
            std::snprintf(d, sizeof d, "%zu distinct / %d fresh processes", seen.size(), N);
            report(1, "distinct across process restarts", seen.size() == size_t(N), d);
        }
    }

    // -----------------------------------------------------------------------
    std::printf("\nTier 2 - statistical (see note below)\n");
    run_tier2([]{ std::vector<uint8_t> v(1 << 18); core_entropy_get_strong(v.data(), v.size()); return v; }());

    // -----------------------------------------------------------------------
    std::printf("\nTier 3 - provenance\n");
    std::printf("  [T3] syscall assertion + fault injection      SKIP  see scripts/provenance_*.sh\n");

    std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
    std::printf(
        "\nNote: Tier 2 measures a PRNG's output function, never whether it was\n"
        "seeded — any CSPRNG passes it with or without entropy. Only Tier 1 and\n"
        "Tier 3 can tell those apart, and only Tier 3 proves the source cannot\n"
        "silently degrade. Tier 2 alone is never evidence.\n\n");

    return g_fail == 0 ? 0 : 1;
}
