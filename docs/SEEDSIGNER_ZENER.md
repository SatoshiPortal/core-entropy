# A Zener entropy source for SeedSigner

Design note. Nothing here is built yet.

Two parts: an audit of how SeedSigner generates seeds today, and a proposal for
adding a Zener avalanche source that does not disturb what already works.

---

## Part 1 — What SeedSigner does today

Audited at `SeedSigner/seedsigner@1fb2956`. Three paths, all in-tree.

### Dice — `helpers/mnemonic_generation.py:76`

```python
entropy_bytes = hashlib.sha256(roll_data.encode()).digest()
```

50 rolls → 12 words, 99 → 24. The dice string is the **only** input.

### Coin flips — `helpers/mnemonic_generation.py:93`

```python
entropy_bytes = hashlib.sha256(coin_flips.encode()).digest()
```

128 flips → 12 words. Same shape.

### Camera image — `views/tools_views.py:145-176`

A hash chain:

```
h = sha256(cpu_serial)                  # /proc/cpuinfo "Serial"
h = sha256(h + str(time.time()))
for frame in preview_frames:            # live preview frames
    h = sha256(h + frame.tobytes())
h = sha256(h + full_res_image.tobytes())
entropy = h[:16]                        # 12 words
```

### The finding

**No OS CSPRNG is mixed into any seed path.** Verified by exhaustive grep over
`src/`: no `os.urandom`, no `secrets`, no `SystemRandom`, no `/dev/urandom`, no
`getrandom`. `embit.bip39.mnemonic_from_bytes` is pure encoding and adds
nothing.

Every SeedSigner seed is a deterministic hash of user or sensor input.

This is deliberate, and for dice and coins it is the right call: it makes the
result **externally verifiable**. Ship `docs/dice_verification.md`, and a user
can reproduce their own mnemonic offline against iancoleman or the bundled CLI.
Mixing in `os.urandom` would destroy that property. The tradeoff is chosen
knowingly.

The consequence is that **no path has an entropy floor.**

| Path | Best case | Failure mode | Detected? |
|---|---|---|---|
| Dice | 50 fair d6 = 129 bits | biased die, fudged rolls, reused pattern | no |
| Coin | 128 fair flips = 128 bits | same | no |
| Camera | image sensor noise | flat subject, bright scene, denoising ISP | no |

For dice and coins the assumption is at least *visible* to the user — they know
they are the source. The camera path is different, and worth looking at
closely.

### The camera path deserves scrutiny

Of its four inputs:

- **CPU serial** is constant for the life of the device and is not secret. It
  contributes nothing after the first seed.
- **`time.time()`** is low entropy and bounded — an attacker who knows the day
  has a small search space.
- **Preview frames and the final image** are therefore carrying essentially all
  of the entropy.

There is no minimum, no health test, and no floor. A photograph of a flat
surface in even light, through an ISP that denoises before the buffer is read,
is not obviously 128 bits — and nothing in the code would notice.

**Recommendation for upstream**, independent of anything below: the camera path
is *already* non-reproducible. A user cannot verify an image-derived seed the
way they can verify a dice seed. So the verifiability argument that justifies
excluding `os.urandom` from dice does **not** apply here, and mixing
`os.urandom(32)` into that chain would cost nothing and establish a floor. The
one caveat worth checking is early-boot behaviour on a headless Pi — Python's
`os.urandom` uses `getrandom(2)`, which blocks until the kernel pool is seeded,
so it is safe but could stall a very early call.

---

## Part 2 — Adding a Zener source

### Principle: a fourth path, not a change to the existing three

Dice and coin verifiability is a feature. Do not touch it. The Zener becomes a
separate menu entry with its own rules.

This is convenient, because a hardware source is **inherently
non-reproducible** — nobody can verify a Zener-derived seed after the fact. So
in this path there is nothing to lose by mixing in the OS CSPRNG, and a floor
to gain.

### Hardware

Based on [reallyreallyrandom.com's Dangerous Box](http://www.reallyreallyrandom.com/zener/dangerous-box/index.html):

| Part | Note |
|---|---|
| BZX85C24 Zener (24 V), 100 kΩ | ~1.1 Vpp avalanche noise |
| 2N7000 MOSFET follower | raises to ~1.6 Vpp, stiffens output impedance |
| Boost converter to 30 V | the real analog design work: a switcher next to a µV measurement |
| RP2040 | 12-bit ADC, ~500 kSa/s, ~$1 |

**Why an RP2040 rather than digitising with a 74HC14 into Pi GPIO:** the
Schmitt-trigger route is simpler and needs no ADC, but it discards the raw
analog distribution. The site's own second golden rule is *measure IID H∞*, and
you cannot estimate min-entropy from already-digitised bits with the same
confidence. Raw samples are also what makes the device falsifiable — the whole
argument of the Dangerous Box page:

> Even x-raying the TRNG cannot show what is happening inside its potted
> micro controller.

A device that emits conditioned bytes is unauditable for exactly the reason
whitened garbage is indistinguishable from whitened entropy. **Emit raw
samples. Condition on the host.**

Lower-voltage alternative if the boost converter proves too noisy: a
reverse-biased 2N3904 base-emitter junction avalanches around 6–9 V, much
easier from 5 V, at the cost of amplitude.

### Protocol

RP2040 → Pi over UART. Framed raw 12-bit samples, no whitening, no
compression, plus a sequence counter so dropped frames are visible.

### Software: the gate

Runs on the Pi, in Python, before anything reaches the seed. For 16 bytes of
output, speed is irrelevant — oversample by orders of magnitude and discard
freely.

```
raw samples
   ├─ RCT  (SP 800-90B repetition count)      → fail ⇒ reject device
   ├─ APT  (SP 800-90B adaptive proportion)   → fail ⇒ reject device
   ├─ min-entropy estimate, IID and non-IID   → below threshold ⇒ reject
   └─ surviving samples
          └─ sha512(samples ‖ os.urandom(32))[:16]  → 12 words
```

Two rules carried over from the rest of this repository:

1. **Hard fail, never degrade.** A device failing health tests is rejected with
   an error on screen. It does not fall back to a shorter sample, a different
   source, or a warning the user can dismiss.
2. **Additive only.** `os.urandom(32)` is in the hash so that a dead diode, a
   cold solder joint, or a saturated amplifier leaves the user no worse off
   than not plugging the device in. The Zener can only add.

Run both the IID and non-IID estimators. IID is the optimistic branch and real
avalanche sources routinely violate it — consecutive ADC samples correlate,
mains hum couples in at 50/60 Hz, and min-entropy drifts with temperature. The
site's ~48 kbit/s figure at 10 kSa/s implies roughly 48% entropy per raw bit,
which is plausible for a good source and is exactly the claim that needs
non-IID estimation behind it.

### What this is and is not better at

SeedSigner's dice have one property the Zener can never have: **the user
watches the randomness happen.** With a diode you are trusting your own
soldering and a datasheet.

So the strongest configuration is not either/or. Dice **and** diode **and**
`os.urandom`, folded together, with none of them load-bearing alone. That is
also the only configuration where a single silent failure cannot produce a weak
seed that looks fine — which is the failure that took five years to surface at
Coinkite.

---

## Build order

1. Host-side gate (RCT, APT, IID + non-IID min-entropy) against **recorded
   sample files**. No hardware required, and it is the part carrying the
   security argument.
2. Breadboard the Dangerous Box; capture samples; run them through the gate.
   This is what tells you whether a given diode build is any good.
3. RP2040 firmware and framing.
4. SeedSigner menu entry and screens.
5. Separately, propose the `os.urandom` floor for the camera path upstream.

Step 1 is shared with the mobile side: the same health tests apply whether the
samples arrive over UART on a Pi or over QR into a phone.
