import 'dart:typed_data';

/// Differenz zweier gleich langer Byte-Folgen: 0 genau dann, wenn gleich.
///
/// Läuft immer über alle Bytes (XOR-Akkumulator, keine frühe Rückkehr), damit
/// die Laufzeit nicht verrät, an welcher Stelle ein Tag abweicht. Das
/// Ergebnis gehört nicht in Logs; Aufrufer verknüpfen mehrere Differenzen mit
/// `|` und prüfen erst am Ende auf 0.
int constantTimeDiff(Uint8List a, Uint8List b) {
  // Die Länge ist öffentlich (feste Tag-Größen), darf also verzweigen.
  if (a.length != b.length) return 1;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff;
}
