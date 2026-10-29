import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'dual_hkdf.dart';

// KDF-Profil (Spezifikation §3.1). Parameter stehen nur hier im Code, nie in
// der Datei: so kann eine fremde Datei keine riesigen Kosten erzwingen.
// `K_A`, `K_S` und `R` gehören nie in Logs, SharedPreferences oder Exceptions.

/// Ein KDF-Profil. Ein neues Profil bekommt neue Salts und damit neue Namen.
class KdfProfile {
  final int id;
  final int argon2MemoryKiB;
  final int argon2Iterations;
  final int argon2Lanes;
  final int scryptN;
  final int scryptR;
  final int scryptP;
  final Uint8List _argon2Salt;
  final Uint8List _scryptSalt;
  final Uint8List _combineSalt;

  // Getter geben Kopien zurück: ein Aufrufer kann die Salts des globalen
  // Profils nicht verändern (das änderte still alle abgeleiteten Schlüssel).
  Uint8List get argon2Salt => Uint8List.fromList(_argon2Salt);
  Uint8List get scryptSalt => Uint8List.fromList(_scryptSalt);
  Uint8List get combineSalt => Uint8List.fromList(_combineSalt);

  KdfProfile({
    required this.id,
    required this.argon2MemoryKiB,
    required this.argon2Iterations,
    required this.argon2Lanes,
    required this.scryptN,
    required this.scryptR,
    required this.scryptP,
    required Uint8List argon2Salt,
    required Uint8List scryptSalt,
    required Uint8List combineSalt,
  })  : _argon2Salt = Uint8List.fromList(argon2Salt),
        _scryptSalt = Uint8List.fromList(scryptSalt),
        _combineSalt = Uint8List.fromList(combineSalt);
}

/// Profil 1 = P-32: Argon2id 32 MiB, t=3 und scrypt 2^16, r=8, beide Ausgaben
/// 64 B. `p = 1`, weil pointycastle Lanes ohnehin nacheinander rechnet.
final KdfProfile kdfProfile1 = KdfProfile(
  id: 1,
  argon2MemoryKiB: 32768,
  argon2Iterations: 3,
  argon2Lanes: 1,
  scryptN: 1 << 16,
  scryptR: 8,
  scryptP: 1,
  argon2Salt: Uint8List.fromList(ascii.encode('ultracipher/kdf/1/argon2id')),
  scryptSalt: Uint8List.fromList(ascii.encode('ultracipher/kdf/1/scrypt')),
  combineSalt: Uint8List.fromList(ascii.encode('ultracipher/kdf/1/combine')),
);

/// Länge von `K_A`, `K_S` und `R`.
const int kdfOutputLength = 64;

final Uint8List _rootInfo =
    Uint8List.fromList(ascii.encode('ultracipher/root'));

/// Allow-List der Profile, die dieser Code kennt (nur Profil 1).
KdfProfile? kdfProfileById(int id) => id == kdfProfile1.id ? kdfProfile1 : null;

/// `utf8(passphrase.trim())`, ohne Unicode-Normalisierung (Entscheidung E5).
Uint8List passphraseBytes(String passphrase) =>
    Uint8List.fromList(utf8.encode(passphrase.trim()));

/// `K_A`: Argon2id (Version 0x13, type 2), ohne `secret` und `ad`.
///
/// Absichtlich über `export.dart`: pointycastle wählt die Implementierung
/// selbst (unter dart2wasm die korrekte Register64-Variante). Die
/// Native-Int-Variante rechnet dort falsch und darf nie erzwungen werden.
Uint8List deriveArgon2idKey(Uint8List passphrase, KdfProfile profile) {
  final generator = Argon2BytesGenerator()
    ..init(Argon2Parameters(
      Argon2Parameters.ARGON2_id,
      profile.argon2Salt,
      desiredKeyLength: kdfOutputLength,
      iterations: profile.argon2Iterations,
      memory: profile.argon2MemoryKiB,
      lanes: profile.argon2Lanes,
      version: Argon2Parameters.ARGON2_VERSION_13,
    ));
  return generator.process(passphrase);
}

/// `K_S`: scrypt.
Uint8List deriveScryptKey(Uint8List passphrase, KdfProfile profile) {
  final scrypt = Scrypt()
    ..init(ScryptParameters(profile.scryptN, profile.scryptR, profile.scryptP,
        kdfOutputLength, profile.scryptSalt));
  return scrypt.process(passphrase);
}

/// `R` aus beiden KDF-Ausgaben: `DualExtract(salt_C, K_A || K_S)`, dann
/// `DualExpand(.., "ultracipher/root", 64)`. Reihenfolge fest: K_A zuerst.
///
/// `R` entsteht nur aus beiden Ausgaben; es gibt keinen billigeren Zwischenweg
/// (Spezifikation §2.4).
Uint8List combineRoot(Uint8List ka, Uint8List ks, KdfProfile profile) {
  if (ka.length != kdfOutputLength || ks.length != kdfOutputLength) {
    throw ArgumentError(
        'K_A und K_S müssen je $kdfOutputLength Byte lang sein');
  }
  final ikm = Uint8List(ka.length + ks.length)
    ..setRange(0, ka.length, ka)
    ..setRange(ka.length, ka.length + ks.length, ks);
  return dualExpand(
      dualExtract(profile.combineSalt, ikm), _rootInfo, kdfOutputLength);
}

/// Komplette, synchrone Ableitung (nacheinander; für Tests und das Modul).
/// Wie `UltracipherApp.deriveRootReal` (parallel, App) geht sie durch
/// [combineRoot]; die eingefrorenen R-Tests binden beide aneinander. Die
/// Parallelisierung in Isolates gehört zur App.
Uint8List deriveRoot(String passphrase, {KdfProfile? profile}) {
  final p = profile ?? kdfProfile1;
  final bytes = passphraseBytes(passphrase);
  return combineRoot(deriveArgon2idKey(bytes, p), deriveScryptKey(bytes, p), p);
}
