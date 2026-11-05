// Hilfen fuer die Tests des Schreiblimits (UltracipherApp.maxWritableFileLength).
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ultracipher_flutter/src/core.dart' show UltracipherApp;

/// Text, den BZip2 kaum verkleinert: die Ciphertext-Groesse folgt der Laenge,
/// sodass ein kleines Limit sicher zwischen "mit" und "ohne" liegt.
String noise(int bytes) {
  var random = Random(7);
  return base64Url.encode([for (var i = 0; i < bytes; i++) random.nextInt(256)]);
}

/// Setzt das Schreiblimit fuer den laufenden Test; danach wieder der Normalwert.
void limitWritesTo(int bytes) {
  var before = UltracipherApp.maxWritableFileLength;
  UltracipherApp.maxWritableFileLength = bytes;
  addTearDown(() => UltracipherApp.maxWritableFileLength = before);
}

/// Die feste Meldung, wie die UI sie zeigt (wortgleich, damit eine Aenderung
/// des Textes im Kern auffaellt).
const String tooLargeMessage = 'The database is too large to save (limit '
    '16 MB). Delete entries, or export CSV and start a new database; nothing '
    'was saved.';
