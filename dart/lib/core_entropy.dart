import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _FillNative = Void Function(Pointer<Uint8>, Size);
typedef _FillDart = void Function(Pointer<Uint8>, int);
typedef _AddNative = Void Function(Pointer<Uint8>, Size);
typedef _AddDart = void Function(Pointer<Uint8>, int);
typedef _EventNative = Void Function(Uint32);
typedef _EventDart = void Function(int);
typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();
typedef _IntNative = Int32 Function();
typedef _IntDart = int Function();
typedef _StrNative = Pointer<Utf8> Function();
typedef _StrDart = Pointer<Utf8> Function();
typedef _SizeNative = Size Function();
typedef _SizeDart = int Function();

/// Bitcoin Core v29.0's RNG, reached through a C ABI.
///
/// Every call either returns full-strength entropy or does not return at all:
/// Core's `GetOSRand()` calls `RandFailure()` -> `std::abort()` when the OS
/// source fails, and the build config admits no `/dev/urandom` fallback
/// branch. There is deliberately no error code to check and no exception to
/// catch — a degraded path would be worse than a crash.
class CoreEntropy {
  CoreEntropy._(DynamicLibrary lib)
      : _getStrong = lib.lookupFunction<_FillNative, _FillDart>(
            'core_entropy_get_strong'),
        _addEntropy =
            lib.lookupFunction<_AddNative, _AddDart>('core_entropy_add_entropy'),
        _addEvent = lib.lookupFunction<_EventNative, _EventDart>(
            'core_entropy_add_event'),
        _reseed = lib.lookupFunction<_VoidNative, _VoidDart>(
            'core_entropy_reseed'),
        _sanityCheck = lib.lookupFunction<_IntNative, _IntDart>(
            'core_entropy_sanity_check'),
        _osSource = lib.lookupFunction<_StrNative, _StrDart>(
            'core_entropy_os_source'),
        _osBlockSize = lib.lookupFunction<_SizeNative, _SizeDart>(
            'core_entropy_os_block_size');

  final _FillDart _getStrong;
  final _AddDart _addEntropy;
  final _EventDart _addEvent;
  final _VoidDart _reseed;
  final _IntDart _sanityCheck;
  final _StrDart _osSource;
  final _SizeDart _osBlockSize;

  static CoreEntropy? _instance;
  static String? _instancePath;

  /// Core's RNG state is a process-wide singleton, so this returns the same
  /// instance for repeated calls. Reopening with a different [path] throws
  /// rather than silently handing back the first library.
  static CoreEntropy open({String? path}) {
    final resolved = path ?? _defaultPath();
    final existing = _instance;
    if (existing != null) {
      if (_instancePath != resolved) {
        throw StateError(
          'CoreEntropy already opened from $_instancePath; cannot reopen from '
          '$resolved. Core\'s RNG state is process-global.',
        );
      }
      return existing;
    }
    _instancePath = resolved;
    return _instance = CoreEntropy._(_load(resolved));
  }

  static DynamicLibrary _load(String resolved) => DynamicLibrary.open(resolved);

  static String _defaultPath() {
    // iOS ships the code as a dynamic framework vendored by the Flutter
    // plugin; Android ships a plain .so in the APK. The desktop paths are for
    // running the Dart tests against a `make lib` build.
    if (Platform.isIOS) return 'CoreEntropy.framework/CoreEntropy';
    if (Platform.isAndroid) return 'libcore_entropy.so';
    if (Platform.isMacOS) return 'build/libcore_entropy.dylib';
    if (Platform.isLinux) return 'build/libcore_entropy.so';
    throw UnsupportedError(
        'no core_entropy build for ${Platform.operatingSystem}');
  }

  /// The syscall this binary was compiled against, e.g. `getrandom(2)`.
  String get osSource => _osSource().toDartString();

  /// Core's `NUM_OS_RANDOM_BYTES`.
  int get osBlockSize => _osBlockSize();

  /// Core's `Random_SanityCheck()`.
  bool sanityCheck() => _sanityCheck() == 1;

  /// `GetStrongRandBytes()` — slow seeding. The only generator this binding
  /// exposes; Core's faster `GetRandBytes()` is deliberately not bound.
  Uint8List strongBytes(int length) => _fill(length, _getStrong);

  /// Mix caller-supplied material into Core's pool.
  ///
  /// Safe with arbitrary input quality: Core folds contributions into the
  /// persistent state through SHA-512 and never replaces it, so this cannot
  /// weaken the pool. Input of any size is SHA-512'd natively and fed to Core
  /// as 16 `RandAddEvent` words. Call [reseed] afterwards to fold it into
  /// extractable output.
  void addEntropy(Uint8List data) {
    if (data.isEmpty) return;
    final buf = calloc<Uint8>(data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      _addEntropy(buf, data.length);
    } finally {
      calloc.free(buf);
    }
  }

  /// Contribute one event, mapping directly onto Core's `RandAddEvent`.
  ///
  /// Prefer this over [addEntropy] for streams of small values. Core mixes a
  /// fresh performance counter alongside each call, so feeding events one at a
  /// time captures one timestamp each; batching them into [addEntropy] does
  /// not.
  ///
  /// Interpreting UI or sensor input into these calls is deliberately not this
  /// library's job — see `package:core_entropy/collectors.dart`.
  void addEvent(int eventInfo) => _addEvent(eventInfo & 0xFFFFFFFF);

  /// Core's `RandAddPeriodic()`.
  void reseed() => _reseed();

  Uint8List _fill(int length, _FillDart fn) {
    if (length <= 0) throw ArgumentError.value(length, 'length', 'must be > 0');
    final buf = calloc<Uint8>(length);
    try {
      fn(buf, length);
      return Uint8List.fromList(buf.asTypedList(length));
    } finally {
      // Zero the native buffer before returning it to the allocator. The Dart
      // copy above is GC-managed and cannot be wiped, which is the unavoidable
      // cost of moving key material across the FFI boundary at all.
      buf.asTypedList(length).fillRange(0, length, 0);
      calloc.free(buf);
    }
  }
}
