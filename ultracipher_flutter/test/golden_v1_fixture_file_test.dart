// Nur VM: gleicht die Literale in golden_v1_vectors.dart (die auch unter WASM
// laufen) mit der eingefrorenen Datei test/fixtures/golden_v1.json ab.
// Die Datei wird NICHT neu erzeugt; ein roter Test ist der Befund (siehe
// golden_v1_test.dart und tool/generate_fixtures_v1.dart).
@TestOn('vm')
library golden_v1_fixture_file_test;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'golden_v1_vectors.dart';

void main() {
  test('golden_v1.json stimmt mit den Literalen ueberein', () {
    final json =
        jsonDecode(File('test/fixtures/golden_v1.json').readAsStringSync())
            as Map<String, dynamic>;
    final d = (json['derivations'] as List).cast<Map<String, dynamic>>();
    expect(json['generatedAt'], '2026-10-28');
    expect(json['hdr12Hex'], hdr12Hex);
    expect(json['fileSaltHex'], fileSaltHex);
    expect(json['plaintext'], frozenPlaintext);
    expect(json['plaintextUtf8Hex'], plaintextUtf8Hex);
    expect(json['fileBase64'], fileBase64);
    expect(json['fileSubkeysHex'], fileSubkeysHex);
    expect(d[0]['passphrase'], passphraseAscii);
    expect(d[0]['passphraseUtf8Hex'], passphraseAsciiUtf8Hex);
    expect(d[0]['kaHex'], kaAsciiHex);
    expect(d[0]['ksHex'], ksAsciiHex);
    expect(d[0]['rootHex'], rootAsciiHex);
    expect(d[1]['passphrase'], passphraseUnicode);
    expect(d[1]['passphraseUtf8Hex'], passphraseUnicodeUtf8Hex);
    expect(d[1]['kaHex'], kaUnicodeHex);
    expect(d[1]['ksHex'], ksUnicodeHex);
    expect(d[1]['rootHex'], rootUnicodeHex);
  });
}
