/// Flutter entry point for core-entropy.
///
/// The FFI binding and the collectors live in `package:core_entropy`; this
/// package exists to carry the native build for Android and iOS and to pick
/// the right load strategy on each. Android loads `libcore_entropy.so` from
/// the APK; iOS links statically, so the symbols are already in the process.
library;

export 'package:core_entropy/collectors.dart';
export 'package:core_entropy/core_entropy.dart';

import 'package:core_entropy/core_entropy.dart';

/// Opens Core's RNG using the platform's bundled native library.
///
/// Throws on any platform where the native library is not present, rather
/// than degrading to a Dart-side generator. There is no software fallback in
/// this package by design.
CoreEntropy openCoreEntropy() => CoreEntropy.open();
