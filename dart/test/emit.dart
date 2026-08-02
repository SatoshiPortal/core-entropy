import 'dart:io';
import 'package:entropy_lab/entropy_lab.dart';

void main() {
  final lab = EntropyLab.open(path: Platform.environment['ENTROPY_LAB_LIB']!);
  final b = lab.strongBytes(32);
  stdout.write(b.map((x) => x.toRadixString(16).padLeft(2, '0')).join());
}
