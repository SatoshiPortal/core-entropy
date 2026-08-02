import 'dart:io';
import 'package:core_entropy/core_entropy.dart';

void main() {
  final lab = CoreEntropy.open(path: Platform.environment['CORE_ENTROPY_LIB']!);
  final b = lab.strongBytes(32);
  stdout.write(b.map((x) => x.toRadixString(16).padLeft(2, '0')).join());
}
