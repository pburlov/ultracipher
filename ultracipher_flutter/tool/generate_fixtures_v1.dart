// Erzeugt das Golden-Vector-Fixture fuer das Ultracipher-Format v1
// (test/fixtures/golden_v1.json, Spezifikation crypto-v1-format.md §9).
//
// WICHTIG: Dieses Skript wird GENAU EINMAL ausgefuehrt (2026-10-28, mit
// ausdruecklichem Ja des Users, Schritt 3 des v1-Plans) und danach NIE wieder,
// ausser der User gibt es ausdruecklich frei. Das Fixture ist eingefroren. Ein
// erneuter Lauf wuerde genau die Referenz ueberschreiben, gegen die
// test/golden_v1_test.dart prueft (Ableitung K_A, K_S, R, Datei-Teilschluessel,
// Entschluesselung und deterministisches seal). Schlaegt ein Golden-Test fehl,
// ist das der Befund -- kein Anlass, dieses Skript zu starten. Zur Sicherheit
// bricht es ab, wenn die Zieldatei schon existiert.
//
// Ebene: Format (FormatV1.seal/open). Der Klartext ist ein fest ausgeschriebener
// Byte-String, nicht die App-Nutzlast (JSON -> BZip2, das ist Schritt 4). Name
// der Datenbank (databaseName) gehoert ebenfalls nicht hierher (Schritt 4).
// Alle Eingaben stehen mit \u-Escapes im Quelltext, damit vorkomponierte und
// zerlegte Zeichen nicht unbemerkt abweichen; das JSON haelt zusaetzlich die
// UTF-8-Bytes als Hex.
//
// Aufruf (aus ultracipher_flutter/, nur in der VM, nie unter WASM):
//   dart run tool/generate_fixtures_v1.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ultracipher_flutter/src/crypto/cascade.dart';
import 'package:ultracipher_flutter/src/crypto/format_v1.dart';
import 'package:ultracipher_flutter/src/crypto/kdf_profile.dart';

const String outputPath = 'test/fixtures/golden_v1.json';

const String passphraseAscii = 'correct horse battery staple 42!';
// "Grüße, 秘密 – ünïcödé!"
const String passphraseUnicode =
    'Grüße, 秘密 – ünïcödé!';

// Festes Klartext-Beispiel (komprimierte Bytes stuenden in der App an dieser
// Stelle). Umlaute, Eszett, CJK, Gedankenstrich, Emoji, Zeilenumbruch, Tab.
const String plaintext = 'Ultracipher v1 Golden-Vektor.\n'
    'Grüße aus München, 秘密 – Schlüssel '
    '\u{1F510}\tEnde.';

// Fester file_salt (32 B), bewusst anders als die Muster in den Unit-Tests.
const String fileSaltHex =
    '7a1f3c9be2045d68a1c7f0329e5b84d60f2ea9137cb86d41e58a30f7c29d1b64';

const String hdr12Hex = '554344420001000100010000';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);

String _pointycastleVersion() {
  final lines = File('pubspec.lock').readAsLinesSync();
  final i = lines.indexWhere((l) => l == '  pointycastle:');
  if (i < 0) throw StateError('pointycastle nicht in pubspec.lock');
  for (var j = i + 1; j < lines.length; j++) {
    final m = RegExp(r'^    version: "(.+)"$').firstMatch(lines[j]);
    if (m != null) return m.group(1)!;
  }
  throw StateError('Version von pointycastle nicht gefunden');
}

Map<String, Object?> _derive(String passphrase) {
  final bytes = passphraseBytes(passphrase);
  final ka = deriveArgon2idKey(bytes, kdfProfile1);
  final ks = deriveScryptKey(bytes, kdfProfile1);
  final root = combineRoot(ka, ks, kdfProfile1);
  return {
    'passphrase': passphrase,
    'passphraseUtf8Hex': _hex(bytes),
    'kaHex': _hex(ka),
    'ksHex': _hex(ks),
    'rootHex': _hex(root),
  };
}

void main() {
  final out = File(outputPath);
  if (out.existsSync()) {
    stderr.writeln('$outputPath existiert bereits: das Fixture ist '
        'eingefroren. Abbruch, nichts geschrieben.');
    exit(1);
  }

  final derivations = [_derive(passphraseAscii), _derive(passphraseUnicode)];
  final root = _unhex(derivations[0]['rootHex'] as String);
  final fileSalt = _unhex(fileSaltHex);
  if (fileSalt.length != 32) throw StateError('file_salt nicht 32 Byte');

  final plainBytes = Uint8List.fromList(utf8.encode(plaintext));
  if (plainBytes.length % 16 == 0) {
    throw StateError('Klartextlaenge darf kein Vielfaches von 16 sein');
  }

  final file = FormatV1.seal(plainBytes, root, fileSalt);
  if (_hex(file.sublist(0, 12)) != hdr12Hex) {
    throw StateError('Header-Praefix weicht von hdr12 ab');
  }
  if (_hex(FormatV1.open(file, root)) != _hex(plainBytes)) {
    throw StateError('open(seal(x)) != x');
  }

  final hdr12 = _unhex(hdr12Hex);
  final keys = FileKeys.derive(root, fileSalt, hdr12);

  final fixture = <String, Object?>{
    'comment': 'Golden vectors fuer das Ultracipher-Format v1 (Ebene '
        'FormatV1.seal/open und Schluesselableitung P-32), einmalig erzeugt am '
        '2026-10-28 mit tool/generate_fixtures_v1.dart. NICHT neu generieren: '
        'ein erneuter Lauf zerstoert die Referenz; ein roter Golden-Test ist '
        'der Befund. Der erwartete Klartext steht von Hand in '
        'test/golden_v1_test.dart.',
    'generatedAt': '2026-10-28',
    'generatedWithPackageVersions': {'pointycastle': _pointycastleVersion()},
    'profile': 'P-32 (Argon2id 32 MiB t=3 p=1 || scrypt 2^16 r=8 p=1)',
    'derivations': derivations,
    'rootUsedForFile': 'derivations[0]',
    'hdr12Hex': hdr12Hex,
    'fileSaltHex': fileSaltHex,
    'fileSubkeysHex': {
      'aes-256-ctr/key': _hex(keys.aesKey),
      'aes-256-ctr/iv': _hex(keys.aesIv),
      'twofish-256-ctr/key': _hex(keys.twofishKey),
      'twofish-256-ctr/iv': _hex(keys.twofishIv),
      'chacha20/key': _hex(keys.chachaKey),
      'chacha20/nonce': _hex(keys.chachaNonce),
      'hmac-sha512/key': _hex(keys.hmacSha512Key),
      'hmac-sha3-256/key': _hex(keys.hmacSha3Key),
    },
    'plaintext': plaintext,
    'plaintextUtf8Hex': _hex(plainBytes),
    'plaintextLength': plainBytes.length,
    'fileLength': file.length,
    'fileBase64': base64.encode(file),
  };

  out.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(fixture)}\n');
  stdout.writeln('geschrieben: $outputPath (${file.length} Byte Datei)');
}
