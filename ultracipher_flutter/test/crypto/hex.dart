import 'dart:typed_data';

Uint8List hex(String s) {
  final clean = s.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16)
  ]);
}

String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List ascii(String s) => Uint8List.fromList(s.codeUnits);

/// 0, 1, 2, ... (mod 256), `n` Bytes.
Uint8List counting(int n, [int start = 0]) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (start + i) & 255]);
