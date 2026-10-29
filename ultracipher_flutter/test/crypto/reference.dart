// Unabhängige Test-Referenz für Dateischlüssel, Kaskade und Format v1. Sie
// benutzt absichtlich keinen Code aus lib/src/crypto, nur pointycastle-
// Primitive und von Hand zusammengesetzte Infos (ein Expand-Block genügt bei
// L <= 64). So fängt ein Vergleich mit `seal` jeden Fehler in Labels, IVs,
// Schichten, MAC-Eingabe und Padding.
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'hex.dart';

Uint8List hmacRef(Digest d, int block, Uint8List key, Uint8List data) {
  final mac = HMac(d, block)..init(KeyParameter(key));
  mac.update(data, 0, data.length);
  final out = Uint8List(mac.macSize);
  mac.doFinal(out, 0);
  return out;
}

Uint8List _cat(List<List<int>> parts) =>
    Uint8List.fromList([for (final p in parts) ...p]);

/// Teilschlüssel nach §3.4 mit einem einzigen Expand-Block je Hash.
Map<String, Uint8List> referenceKeys(
    Uint8List root, Uint8List fileSalt, Uint8List hdr12) {
  final f1 = hmacRef(SHA512Digest(), 128, fileSalt, root);
  final f2 = hmacRef(SHA3Digest(512), 72, fileSalt, root);
  Uint8List k(String label, int len) {
    final info = _cat([
      ascii('ultracipher/file/$label'),
      [0],
      hdr12,
      [1]
    ]);
    final a = hmacRef(SHA512Digest(), 128, f1, info);
    final b = hmacRef(SHA3Digest(512), 72, f2, info);
    return Uint8List.fromList([for (var i = 0; i < len; i++) a[i] ^ b[i]]);
  }

  return {
    'aes-256-ctr/key': k('aes-256-ctr/key', 32),
    'aes-256-ctr/iv': k('aes-256-ctr/iv', 16),
    'twofish-256-ctr/key': k('twofish-256-ctr/key', 32),
    'twofish-256-ctr/iv': k('twofish-256-ctr/iv', 16),
    'chacha20/key': k('chacha20/key', 32),
    'chacha20/nonce': k('chacha20/nonce', 12),
    'hmac-sha512/key': k('hmac-sha512/key', 64),
    'hmac-sha3-256/key': k('hmac-sha3-256/key', 64),
  };
}

/// CTR-Schlüsselstrom über Blockchiffre-ECB und handgeführten 128-Bit-Zähler
/// (unabhängig von pointycastles SIC-Klasse).
Uint8List ctrKeystream(BlockCipher cipher, Uint8List key, Uint8List iv, int n) {
  cipher.init(true, KeyParameter(key));
  final counter = Uint8List.fromList(iv);
  final out = Uint8List(n);
  final block = Uint8List(16);
  for (var off = 0; off < n; off += 16) {
    cipher.processBlock(counter, 0, block, 0);
    for (var i = 0; i < 16 && off + i < n; i++) {
      out[off + i] = block[i];
    }
    for (var j = 15; j >= 0; j--) {
      counter[j] = (counter[j] + 1) & 255;
      if (counter[j] != 0) break;
    }
  }
  return out;
}

Uint8List aesKeystream(Uint8List key, Uint8List iv, int n) =>
    ctrKeystream(AESEngine(), key, iv, n);

Uint8List twofishKeystream(Uint8List key, Uint8List iv, int n) =>
    ctrKeystream(TwofishEngine(), key, iv, n);

Uint8List chachaKeystream(Uint8List key, Uint8List nonce, int n) {
  final c = ChaCha7539Engine()
    ..init(true, ParametersWithIV(KeyParameter(key), nonce));
  final out = Uint8List(n);
  c.processBytes(Uint8List(n), 0, n, out, 0);
  return out;
}

Uint8List xorAll(List<Uint8List> parts) {
  final out = Uint8List(parts.first.length);
  for (final p in parts) {
    for (var i = 0; i < out.length; i++) {
      out[i] ^= p[i];
    }
  }
  return out;
}

Uint8List padRef(Uint8List plain) {
  final n = plain.length + 16 - plain.length % 16;
  final out = Uint8List(n)..setRange(0, plain.length, plain);
  out[plain.length] = 0x80;
  return out;
}

/// Komplette Datei nach §6, ohne Code aus lib/src/crypto.
Uint8List referenceSeal(Uint8List plain, Uint8List root, Uint8List fileSalt) {
  final hdr12 = hex('55434442 0001 0001 0001 0000');
  final header = _cat([hdr12, fileSalt]);
  final keys = referenceKeys(root, fileSalt, hdr12);
  final padded = padRef(plain);
  final n = padded.length;
  final c = xorAll([
    padded,
    aesKeystream(keys['aes-256-ctr/key']!, keys['aes-256-ctr/iv']!, n),
    twofishKeystream(
        keys['twofish-256-ctr/key']!, keys['twofish-256-ctr/iv']!, n),
    chachaKeystream(keys['chacha20/key']!, keys['chacha20/nonce']!, n),
  ]);
  final m = _cat([header, c]);
  final t1 = hmacRef(SHA512Digest(), 128, keys['hmac-sha512/key']!, m);
  final t2 = hmacRef(SHA3Digest(256), 136, keys['hmac-sha3-256/key']!, m);
  return _cat([m, t1, t2]);
}
