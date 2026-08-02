import 'dart:async';
import 'dart:math' as math;

import 'package:core_entropy_flutter/core_entropy_flutter.dart';
import 'package:flutter/material.dart';

void main() => runApp(const CoreEntropyDemo());

class CoreEntropyDemo extends StatelessWidget {
  const CoreEntropyDemo({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'core-entropy',
        theme: ThemeData.dark(useMaterial3: true),
        home: const _Home(),
      );
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  CoreEntropy? _rng;
  PointerEntropyCollector? _pointer;
  String? _error;
  String _entropy = '';
  int _draws = 0;

  /// Live feedback, published without rebuilding the whole page: pointer
  /// events arrive far faster than the frame rate.
  ///
  /// Deliberately an *activity* meter rather than a progress bar. A bar that
  /// fills toward a target would imply the seed needs your input to be safe.
  /// It does not — its strength comes from the OS source, and these samples
  /// are additive only. So the meter shows that input is being captured right
  /// now, and decays to empty when you stop.
  final _feedback = ValueNotifier<(int, double)>((0, 0));
  Timer? _decay;

  @override
  void initState() {
    super.initState();
    try {
      final rng = openCoreEntropy();
      _rng = rng;
      _pointer = PointerEntropyCollector(rng);
      _draw();
    } catch (e) {
      _error = '$e';
    }
  }

  @override
  void dispose() {
    _decay?.cancel();
    _feedback.dispose();
    super.dispose();
  }

  void _feed(Offset p) {
    final c = _pointer;
    if (c == null) return;
    c.sample(p.dx, p.dy);
    final (_, level) = _feedback.value;
    _feedback.value = (c.sampleCount, math.min(1.0, level + 0.06));
    _decay ??= Timer.periodic(const Duration(milliseconds: 60), (t) {
      final (n, l) = _feedback.value;
      if (l <= 0.001) {
        t.cancel();
        _decay = null;
        _feedback.value = (n, 0);
        return;
      }
      _feedback.value = (n, l * 0.82);
    });
  }

  void _draw() {
    final bytes = _rng!.strongBytes(16);
    setState(() {
      _entropy = bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .replaceAllMapped(RegExp(r'.{8}'), (m) => '${m[0]} ')
          .trim();
      _draws++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final rng = _rng;
    if (rng == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Native library unavailable:\n$_error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('core-entropy')),
      body: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _feed(e.position),
        onPointerMove: (e) => _feed(e.position),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Row('OS source', rng.osSource),
              _Row('GetOSRand block', '${rng.osBlockSize} bytes'),
              _Row('Core sanity check', rng.sanityCheck() ? 'pass' : 'FAIL'),
              const Divider(height: 32),
              ValueListenableBuilder<(int, double)>(
                valueListenable: _feedback,
                builder: (context, v, _) =>
                    _PointerFeedback(count: v.$1, level: v.$2),
              ),
              const SizedBox(height: 20),
              const Text('128-bit draw from GetStrongRandBytes()'),
              const SizedBox(height: 8),
              SelectableText(
                _entropy.isEmpty ? '—' : _entropy,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 16,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$_draws draws this session',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _draw,
                  child: const Text('Draw entropy'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "Contributions are folded into Core's pool through SHA-512 and "
                'can never weaken it. They are also not counted toward the '
                "seed: its strength comes from the OS source above, not from "
                'anything you do here.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Live confirmation that a drag is reaching Core's pool.
///
/// Every sample is one RandAddEvent call, and each one also captures a fresh
/// performance counter — the arrival timing is the part that carries entropy,
/// not the coordinates.
class _PointerFeedback extends StatelessWidget {
  const _PointerFeedback({required this.count, required this.level});

  /// Cumulative samples contributed this session.
  final int count;

  /// Recent activity, 0..1, decaying to zero when input stops.
  final double level;

  static const int _bars = 40;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = level > 0.01;
    final lit = (level * _bars).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              active ? Icons.graphic_eq : Icons.touch_app_outlined,
              size: 18,
              color: active ? scheme.primary : scheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                count == 0
                    ? 'Drag anywhere to contribute pointer entropy'
                    : '$count samples fed to RandAddEvent',
                style: TextStyle(
                  color: active ? scheme.primary : scheme.outline,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 16,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(_bars, (i) {
              final on = i < lit;
              return Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 90),
                  height: on ? 16.0 : 4.0,
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(
                    color: on
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(width: 170, child: Text(label)),
            Text(
              value,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
}
