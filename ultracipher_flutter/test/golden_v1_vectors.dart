// Von Hand gepflegte Literale des eingefrorenen v1-Fixtures (siehe
// golden_v1_test.dart). Kein dart:io, damit die Tests auch unter WASM laufen
// (der Browser kann test/fixtures/golden_v1.json nicht lesen).
// golden_v1_fixture_file_test.dart (nur VM) prueft, dass die Datei
// test/fixtures/golden_v1.json mit diesen Literalen uebereinstimmt.
//
// EINGEFROREN am 2026-10-28 (tool/generate_fixtures_v1.dart, einmalig, mit
// Freigabe des Users). NICHT neu erzeugen, NICHT "korrigieren": ein roter
// Golden-Test ist der Befund.

// Klartext (Formatebene, wie er an seal geht): von Hand ausgeschrieben,
// nicht aus dem Generator abgeleitet. 84 UTF-8-Bytes, kein Vielfaches von 16.
const String frozenPlaintext = 'Ultracipher v1 Golden-Vektor.\n'
    'Gr\u00fc\u00dfe aus M\u00fcnchen, \u79d8\u5bc6 \u2013 Schl\u00fcssel '
    '\u{1F510}\tEnde.';

const String passphraseAscii = 'correct horse battery staple 42!';
// "Grüße, 秘密 – ünïcödé!"
const String passphraseUnicode =
    'Gr\u00fc\u00dfe, \u79d8\u5bc6 \u2013 \u00fcn\u00efc\u00f6d\u00e9!';

const String hdr12Hex = '554344420001000100010000';

const String fileSaltHex =
    '7a1f3c9be2045d68a1c7f0329e5b84d60f2ea9137cb86d41e58a30f7c29d1b64';

const String passphraseAsciiUtf8Hex =
    '636f727265637420686f727365206261747465727920737461706c6520343221';

const String kaAsciiHex =
    'c07b46b2f8c4e390a9e1af62d11213237e60a3451cfd2de74b0c0f8696b50831'
    '71e912363193e2e78cb3590a92e155f95370a64e8f9239d81d69b925e29bb8d9';

const String ksAsciiHex =
    'a9e0cb19d1ab72db27d29bc4524ab8fcbb668818dff11eb9166a669e102d183b'
    '281c0609680f7935850027ae2ea18b76b864308b274aca970d12a5b0e4118245';

const String rootAsciiHex =
    '55d31c3dc9da1496d013e6026044436361a7590153657f11df2c042432fd6c91'
    '924e624d5f25e1dbd4e9267d83e3f926199ade69e5eb3dc4686888fd3d323218';

const String passphraseUnicodeUtf8Hex =
    '4772c3bcc39f652c20e7a798e5af8620e2809320c3bc6ec3af63c3b664c3a921';

const String kaUnicodeHex =
    'a730119c6643a01503285fa4341bf75111050f0b6f68c611a5c014f57bf3b871'
    '4984f34e82b3149d9482660ab7f1c9cd1a086d85fd67f2fd3e98dfbcb1920938';

const String ksUnicodeHex =
    '204a9e9911cf8667708950f77f8df26abc08ac59b7cbba7350a69e07a4d4f577'
    'e151750b9c0324835f98bb65d5ac8beefb9730ba30394cfb38acb6921bcf93e8';

const String rootUnicodeHex =
    '12f1b5fefe82309ba93eb3ee658d79889e68485935d610bf85d04ba7868edf7c'
    '57a4c756d6d3a1640e321285f1d9789a5dd2beab5949f777095284ff3cb582fa';

/// Die acht Teilschluessel zu `rootAsciiHex` und `fileSaltHex`.
const Map<String, String> fileSubkeysHex = {
  'aes-256-ctr/key':
      'd82e9f679baf5f35687c5ce23c070097469f8a284258ec7c29295c91ef8fcc74',
  'aes-256-ctr/iv': '20fbd274adc81b1268bc51c1dd31e004',
  'twofish-256-ctr/key':
      '9d6c7e3393b5ec8907f6ae38ebc8cea14a75807863427f39271f6f1eb60d2fc6',
  'twofish-256-ctr/iv': '2fa834f97a624d9b6cd43d27152f1698',
  'chacha20/key':
      '8909a21481b435c8003dbeeece76ac4e9f1b144232b9f895b164ca3cd79d4845',
  'chacha20/nonce': 'bd02f91d424dbe6851241d6c',
  'hmac-sha512/key':
      '07eed475884a77007f83460e55eecf2deeab68b8ccff9f8d95ef00c6b0c8d937'
          '842ed35de1834a98962171168ded506d1967c6deb1f542156f013f27c48c941c',
  'hmac-sha3-256/key':
      '4d2b15dac53143332c38c5c5956e0efa3ef845d444d51f58e4f44c22fd1ece17'
          '7a0d0a1f65390d1e1635d5f2222eec6722a24bd611af8faac19f3c40d5407910',
};

const String plaintextUtf8Hex =
    '556c74726163697068657220763120476f6c64656e2d56656b746f722e0a4772'
    'c3bcc39f6520617573204dc3bc6e6368656e2c20e7a798e5af8620e280932053'
    '63686cc3bc7373656c20f09f949009456e64652e';

const String fileBase64 =
    'VUNEQgABAAEAAQAAeh88m+IEXWihx/AynluE1g8uqRN8uG1B5Yow98KdG2Tqk75Y'
    'acycgfx83S1sBTwa2RASjgSihVA9tlbueK+ii/VsvyG2AO+3ZKWjLdrqf/Y4n/2J'
    '9HBk8oDmQYzem0AndF9K6ZlnuNT3qoHpMU6oDPziJCvkgHLU+PWU8iqNFYpKkNG+'
    'Q+G5DHF4C/RYCmX2YKSV8EH6yqcpn9dVdEob2Am9bvP15x5wQL2W267CEJcjJj0i'
    '5aYlyDhnaoPQZNe4UUTHoRY8U/WzHZeNZmEvPul9sDvxeUdPsMazKKYFvtg=';
