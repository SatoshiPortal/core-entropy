import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _FillNative = Void Function(Pointer<Uint8>, Size);
typedef _FillDart = void Function(Pointer<Uint8>, int);
typedef _AddNative = Void Function(Pointer<Uint8>, Size);
typedef _AddDart = void Function(Pointer<Uint8>, int);
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
  CoreEntropy._(this._lib)
      : _getStrong = _lib.lookupFunction<_FillNative, _FillDart>(
            'core_entropy_get_strong'),
        _getBytes = _lib.lookupFunction<_FillNative, _FillDart>(
            'core_entropy_get_bytes'),
        _addEntropy =
            _lib.lookupFunction<_AddNative, _AddDart>('core_entropy_add_entropy'),
        _reseed = _lib.lookupFunction<_VoidNative, _VoidDart>(
            'core_entropy_reseed'),
        _sanityCheck = _lib.lookupFunction<_IntNative, _IntDart>(
            'core_entropy_sanity_check'),
        _osSource = _lib.lookupFunction<_StrNative, _StrDart>(
            'core_entropy_os_source'),
        _osBlockSize = _lib.lookupFunction<_SizeNative, _SizeDart>(
            'core_entropy_os_block_size');

  final DynamicLibrary _lib;
  final _FillDart _getStrong;
  final _FillDart _getBytes;
  final _AddDart _addEntropy;
  final _VoidDart _reseed;
  final _IntDart _sanityCheck;
  final _StrDart _osSource;
  final _SizeDart _osBlockSize;

  static CoreEntropy? _instance;

  static CoreEntropy open({String? path}) {
    if (_instance != null) return _instance!;
    final resolved = path ?? _defaultPath();
    return _instance = CoreEntropy._(DynamicLibrary.open(resolved));
  }

  static String _defaultPath() {
    if (Platform.isMacOS) return 'build/libcore_entropy.dylib';
    if (Platform.isAndroid) return 'libcore_entropy.so';
    if (Platform.isLinux) return 'build/libcore_entropy.so';
    if (Platform.isIOS) return DynamicLibrary.process().toString();
    throw UnsupportedError('no core_entropy build for ${Platform.operatingSystem}');
  }

  /// The syscall this binary was compiled against, e.g. `getrandom(2)`.
  String get osSource => _osSource().toDartString();

  /// Core's `NUM_OS_RANDOM_BYTES`.
  int get osBlockSize => _osBlockSize();

  /// Core's `Random_SanityCheck()`.
  bool sanityCheck() => _sanityCheck() == 1;

  /// `GetStrongRandBytes()` — slow seeding, for key material.
  Uint8List strongBytes(int length) => _fill(length, _getStrong);

  /// `GetRandBytes()` — fast path, for non-key uses.
  Uint8List bytes(int length) => _fill(length, _getBytes);

  /// Mix caller-supplied material into Core's pool.
  ///
  /// Safe with arbitrary input quality: Core folds contributions into the
  /// persistent state through SHA-512 and never replaces it, so this cannot
  /// weaken the pool. Goes in as `ceil(length/4)` `RandAddEvent` words.
  /// Call [reseed] afterwards to fold it into extractable output.
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
