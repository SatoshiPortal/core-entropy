/// End-to-end demonstration: Bitcoin Core's RNG -> BIP39 mnemonic.
///
///   dart run bin/generate_seed.dart
///   dart run bin/generate_seed.dart --words 24
///   dart run bin/generate_seed.dart --dice          interactive dice entry
///   dart run bin/generate_seed.dart --collectors    simulated sensor input
///   dart run bin/generate_seed.dart --show-fail     prove it panics
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:bip39_mnemonic/bip39_mnemonic.dart' as bip39;
import 'package:core_entropy/collectors.dart';
import 'package:core_entropy/core_entropy.dart';

const _libEnv = 'CORE_ENTROPY_LIB';

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    print(_usage);
    return;
  }

  final wordCount = _intFlag(args, '--words') ?? 12;
  final entropyBytes = switch (wordCount) {
    12 => 16,
    15 => 20,
    18 => 24,
    21 => 28,
    24 => 32,
    _ => throw ArgumentError('--words must be 12, 15, 18, 21 or 24'),
  };

  final rng = CoreEntropy.open(path: Platform.environment[_libEnv]);

  _header(rng);

  if (args.contains('--show-fail')) {
    _explainFailClosed();
    return;
  }

  if (args.contains('--collectors')) _runCollectors(rng);
  if (args.contains('--dice')) _runDice(rng);

  stdout.writeln('Drawing $entropyBytes bytes via GetStrongRandBytes()...');
  final entropy = rng.strongBytes(entropyBytes);

  final mnemonic = bip39.Mnemonic(entropy, bip39.Language.english);

  stdout
    ..writeln()
    ..writeln('entropy   ${_hex(entropy)}')
    ..writeln('bits      ${entropyBytes * 8}')
    ..writeln()
    ..writeln('mnemonic');
  final words = mnemonic.words;
  for (var i = 0; i < words.length; i += 4) {
    final row = <String>[];
    for (var j = i; j < i + 4 && j < words.length; j++) {
      row.add('${(j + 1).toString().padLeft(2)}. ${words[j].padRight(10)}');
    }
    stdout.writeln('  ${row.join()}');
  }
  stdout
    ..writeln()
    ..writeln('This is a demonstration. Do not fund a wallet from a seed')
    ..writeln('printed to a terminal and scrolled into your shell history.');
}

void _header(CoreEntropy rng) {
  stdout
    ..writeln()
    ..writeln('core-entropy :: Bitcoin Core v29.0 RNG')
    ..writeln('  OS source        ${rng.osSource}')
    ..writeln('  GetOSRand block  ${rng.osBlockSize} bytes')
    ..writeln('  sanity check     ${rng.sanityCheck() ? "pass" : "FAIL"}')
    ..writeln();
}

/// Simulated sensor input. In a Flutter app these would be driven by a
/// Listener, a camera stream, and a dice-entry screen respectively.
void _runCollectors(CoreEntropy rng) {
  stdout.writeln('Contributing simulated sensor entropy...');

  final pointer = PointerEntropyCollector(rng);
  for (var i = 0; i < 250; i++) {
    pointer.sample(i * 1.7, i * 2.3);
  }
  stdout.writeln('  pointer  ${pointer.sampleCount} samples');

  final camera = CameraEntropyCollector(rng);
  camera.frame(Uint8List.fromList(List.generate(640 * 480, (i) => i & 0xff)));
  stdout.writeln('  camera   ${camera.frameCount} frame (640x480)');

  rng.reseed();
  stdout
    ..writeln('  reseeded via RandAddPeriodic()')
    ..writeln();
}

/// Interactive dice. The point is not the face values — it is that each
/// keystroke's arrival time is captured by the performance counter Core mixes
/// alongside every RandAddEvent call.
void _runDice(CoreEntropy rng) {
  final dice = DiceEntropyCollector(rng);
  stdout
    ..writeln('Dice entry. Type faces 1-6, then Enter on an empty line.')
    ..writeln('Timing of each entry is mixed in alongside the value.')
    ..writeln();

  while (true) {
    stdout.write('  roll ${dice.rollCount + 1} '
        '(~${dice.entropyBitsUpperBound.toStringAsFixed(1)} bits max) > ');
    final line = stdin.readLineSync();
    if (line == null || line.trim().isEmpty) break;
    final face = int.tryParse(line.trim());
    if (face == null) {
      stdout.writeln('  not a number');
      continue;
    }
    try {
      dice.roll(face);
    } on RangeError {
      stdout.writeln('  must be 1-6');
    }
  }

  dice.commit();
  stdout
    ..writeln()
    ..writeln('  ${dice.rollCount} rolls contributed, '
        '<= ${dice.entropyBitsUpperBound.toStringAsFixed(1)} bits.')
    ..writeln('  Upper bound on a fair, honestly-entered roll — not a')
    ..writeln('  measurement, and not counted toward the seed\'s security.')
    ..writeln();
}

void _explainFailClosed() {
  stdout
    ..writeln('This build has no /dev/urandom fallback. If the OS entropy')
    ..writeln('source fails, Core calls RandFailure() -> std::abort().')
    ..writeln()
    ..writeln('To observe it, from the repository root:')
    ..writeln()
    ..writeln('  ./scripts/provenance_test.sh')
    ..writeln()
    ..writeln('It interposes the syscall, forces failure, and requires')
    ..writeln('SIGABRT (exit 134). A build with a reachable fallback exits 0.')
    ..writeln();
}

int? _intFlag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i == -1 || i + 1 >= args.length) return null;
  return int.tryParse(args[i + 1]);
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

const _usage = '''
core-entropy example

  dart run bin/generate_seed.dart [options]

  --words N       12, 15, 18, 21 or 24   (default 12)
  --collectors    contribute simulated pointer and camera entropy
  --dice          interactive dice entry
  --show-fail     explain how to observe the fail-closed behaviour
  --help

Set $_libEnv to the built shared library if it is not at the
default relative path.
''';
