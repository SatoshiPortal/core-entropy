/// Application-side entropy collectors.
///
/// Deliberately separate from `core_entropy.dart`. That library is a thin FFI
/// binding over Bitcoin Core's RNG and is kept small so a Core developer can
/// review it; deciding how to turn a camera frame or a finger swipe into
/// `RandAddEvent` calls is an application concern with no place in it.
///
/// Nothing here is load-bearing. Core's pool is already seeded from the OS
/// CSPRNG before any of this runs, and contributions are folded in through
/// SHA-512 without ever replacing state, so a collector cannot weaken the
/// pool no matter how poor its input. Equally, none of these can be *counted*
/// toward an entropy budget without a real min-entropy assessment
/// (NIST SP 800-90B). Treat them as defence in depth against a compromised OS
/// RNG, not as a source you can put a number on.
library;

import 'dart:typed_data';

import 'package:core_entropy/core_entropy.dart';

/// Feeds pointer samples — taps, drags, swipes — one event at a time.
///
/// The coordinates carry little entropy; the arrival timing carries most of
/// it, and Core captures that itself via the performance counter it mixes
/// alongside every [CoreEntropy.addEvent] call. Sampling per-event rather
/// than batching is therefore the whole point.
///
/// ```dart
/// Listener(
///   onPointerMove: (e) => collector.sample(e.position.dx, e.position.dy),
///   child: ...,
/// )
/// ```
class PointerEntropyCollector {
  PointerEntropyCollector(this._rng);

  final CoreEntropy _rng;
  int _count = 0;

  int get sampleCount => _count;

  void sample(double x, double y) {
    final xi = (x * 1000).round() & 0xFFFF;
    final yi = (y * 1000).round() & 0xFFFF;
    _rng.addEvent(xi | (yi << 16));
    _count++;
  }

  /// Fold everything collected so far into the extractable state.
  void commit() => _rng.reseed();
}

/// Feeds dice rolls, one call per roll so each captures its own timing.
///
/// A d6 carries at most log2(6) ~ 2.58 bits, so 50 rolls is ~128 bits *if*
/// the user rolls fairly and enters honestly — neither of which the library
/// can verify. [entropyBitsUpperBound] is exactly that: an upper bound, useful
/// for a progress indicator, not a guarantee.
class DiceEntropyCollector {
  DiceEntropyCollector(this._rng, {this.sides = 6});

  final CoreEntropy _rng;
  final int sides;
  final List<int> _rolls = [];

  int get rollCount => _rolls.length;

  double get entropyBitsUpperBound =>
      _rolls.length * (_log2(sides.toDouble()));

  void roll(int face) {
    if (face < 1 || face > sides) {
      throw RangeError.range(face, 1, sides, 'face');
    }
    _rolls.add(face);
    _rng.addEvent(face);
  }

  void commit() => _rng.reseed();

  static double _log2(double x) => x <= 0 ? 0 : (_ln(x) / _ln(2));
  static double _ln(double x) {
    // dart:math is intentionally not imported here; see library docs — this
    // file must not depend on anything that could pull in a PRNG.
    var result = 0.0;
    var y = (x - 1) / (x + 1);
    final y2 = y * y;
    for (var n = 1; n <= 99; n += 2) {
      result += y / n;
      y *= y2;
    }
    return 2 * result;
  }
}

/// Feeds camera frames.
///
/// Sensor noise in the low bits of a raw frame is a real physical source, but
/// a frame is also mostly redundant: adjacent pixels correlate, and any
/// hardware denoising or JPEG stage strips exactly the noise you wanted.
/// Pass the rawest buffer available.
///
/// Frames go through [CoreEntropy.addEntropy], which SHA-512s them natively
/// before handing 16 words to Core — feeding a megabyte four bytes at a time
/// across FFI would be pathological.
class CameraEntropyCollector {
  CameraEntropyCollector(this._rng);

  final CoreEntropy _rng;
  int _frames = 0;

  int get frameCount => _frames;

  void frame(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _rng.addEntropy(bytes);
    _frames++;
  }

  void commit() => _rng.reseed();
}
