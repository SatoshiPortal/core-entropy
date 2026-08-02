import 'dart:io';
import 'dart:typed_data';

import 'package:core_entropy/collectors.dart';
import 'package:core_entropy/core_entropy.dart';
import 'package:test/test.dart';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final libPath = Platform.environment['CORE_ENTROPY_LIB'] ??
      '${Directory.current.parent.path}/build/libcore_entropy.dylib';

  late CoreEntropy lab;

  setUpAll(() {
    lab = CoreEntropy.open(path: libPath);
  });

  group('binding', () {
    test('reports the compiled-in OS source', () {
      expect(lab.osSource, isNotEmpty);
      expect(lab.osSource, anyOf('getrandom(2)', 'getentropy(2)'));
    });

    test('GetOSRand block size matches Core NUM_OS_RANDOM_BYTES', () {
      expect(lab.osBlockSize, 32);
    });

    test("Core's own sanity check passes", () {
      expect(lab.sanityCheck(), isTrue);
    });
  });

  group('tier 1 - catastrophic', () {
    test('returns the requested length', () {
      for (final n in [1, 16, 31, 32, 33, 64, 256]) {
        expect(lab.strongBytes(n).length, n, reason: 'length $n');
      }
    });

    test('rejects non-positive lengths', () {
      expect(() => lab.strongBytes(0), throwsArgumentError);
      expect(() => lab.strongBytes(-1), throwsArgumentError);
    });

    test('output is not all-zero', () {
      expect(lab.strongBytes(64).every((b) => b == 0), isFalse);
    });

    test('crosses the 32-byte chunk boundary without repeating', () {
      // ProcRand asserts num <= 32, so >32 requests are issued as successive
      // draws. A chunking bug shows up as a repeated 32-byte block.
      final b = lab.strongBytes(96);
      final c1 = _hex(Uint8List.fromList(b.sublist(0, 32)));
      final c2 = _hex(Uint8List.fromList(b.sublist(32, 64)));
      final c3 = _hex(Uint8List.fromList(b.sublist(64, 96)));
      expect({c1, c2, c3}.length, 3);
    });

    test('20k draws of 16 bytes are all distinct', () {
      final seen = <String>{};
      for (var i = 0; i < 20000; i++) {
        seen.add(_hex(lab.strongBytes(16)));
      }
      expect(seen.length, 20000);
    });

    test('distinct across fresh processes', () {
      // The failure that costs money is every install producing one seed.
      // It is invisible inside a single process.
      final seen = <String>{};
      for (var i = 0; i < 8; i++) {
        final r = Process.runSync(
          Platform.resolvedExecutable,
          ['run', 'test/emit.dart'],
          environment: {'CORE_ENTROPY_LIB': libPath},
          workingDirectory: Directory.current.path,
        );
        expect(r.exitCode, 0, reason: r.stderr.toString());
        seen.add((r.stdout as String).trim());
      }
      expect(seen.length, 8);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('collectors (application layer)', () {
    // Every value fed to the pool in these tests comes from
    // GetStrongRandBytes(). Nothing in this repository generates or feeds
    // low-entropy material, including in tests: there is no weak input here
    // to be copied into production code or to be mistaken for an acceptable
    // source.
    test('pointer samples feed events and do not degrade output', () {
      final c = PointerEntropyCollector(lab);
      final coords = lab.strongBytes(400);
      for (var i = 0; i < 200; i++) {
        c.sample(coords[i * 2].toDouble(), coords[i * 2 + 1].toDouble());
      }
      expect(c.sampleCount, 200);
      c.commit();
      expect(lab.strongBytes(32).every((b) => b == 0), isFalse);
    });

    test('dice reject out-of-range faces and bound their own claim', () {
      final c = DiceEntropyCollector(lab);
      expect(() => c.roll(0), throwsRangeError);
      expect(() => c.roll(7), throwsRangeError);
      final faces = lab.strongBytes(50);
      for (final f in faces) {
        c.roll((f % 6) + 1);
      }
      expect(c.rollCount, 50);
      expect(c.entropyBitsUpperBound, closeTo(129.2, 1.0));
      c.commit();
    });

    test('camera frames accept bulk input', () {
      final c = CameraEntropyCollector(lab);
      c.frame(Uint8List(0));
      expect(c.frameCount, 0, reason: 'empty frames are ignored');
      c.frame(lab.strongBytes(1 << 18));
      expect(c.frameCount, 1);
      c.commit();
      expect(lab.strongBytes(32).length, 32);
    });
  });

  group('caller-supplied entropy', () {
    test('accepts contributed material and keeps producing output', () {
      lab.addEntropy(lab.strongBytes(64));
      lab.reseed();
      expect(lab.strongBytes(32).every((b) => b == 0), isFalse);
    });

    test('contribution changes the extractable state', () {
      // Core folds contributions into the persistent state through SHA-512
      // and never replaces it, so a contribution can only ever add.
      final before = _hex(lab.strongBytes(32));
      lab.addEntropy(lab.strongBytes(256));
      lab.reseed();
      final after = _hex(lab.strongBytes(32));
      expect(before, isNot(after));
      expect(after.length, 64);
    });

    test('handles lengths that are not a multiple of 4', () {
      for (final n in [1, 2, 3, 5, 7, 13]) {
        lab.addEntropy(lab.strongBytes(n));
      }
      lab.reseed();
      expect(lab.strongBytes(32).length, 32);
    });
  });
}
