// Beschleunigt die App-Tests: die KDF-Ableitung von `R` (Argon2id 32 MiB plus
// scrypt 2^16, ca. 0,5 s nativ) wird pro Passphrase nur einmal pro
// Testprozess echt gerechnet und danach aus einem Speicher geliefert. Die
// Werte sind die echten (gleich wie `UltracipherApp.deriveRootReal`), nur
// nicht jedes Mal neu berechnet. Eingebunden wird das per Datei mit
// useMemoizedKeyDerivation() am Anfang von main(); Tests, deren Gegenstand
// die Ableitung selbst ist (golden_v1_test, user_key_hash_golden_test,
// database_name_test, crypto_behaviour_test), lassen es weg und rechnen echt.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/crypto/kdf_profile.dart'
    show passphraseBytes;

final Map<String, Future<Uint8List>> _memo = {};

/// Wie oft die Testnaht seit dem letzten [resetRootDerivationCount] gefragt
/// wurde (auch Treffer im Speicher). So pruefen Tests, wo die App ableitet
/// (Oeffnen: ja; Speichern, Sync, Export, GitHub: nie, Passwortwechsel:
/// zweimal).
int rootDerivationCount = 0;

void resetRootDerivationCount() => rootDerivationCount = 0;

Future<Uint8List> _memoized(Uint8List bytes) async {
  rootDerivationCount++;
  var memoKey = base64.encode(bytes);
  // In der Root-Zone gestartet: ein Future, das zuerst in einem
  // testWidgets-Body (FakeAsync-Zone) entsteht, wuerde seine Fortsetzungen in
  // dieser Zone einplanen und in einem spaeteren Test haengen.
  var real = _memo.putIfAbsent(memoKey,
      () => Zone.root.run(() => UltracipherApp.deriveRootReal(bytes)));
  // Eine gescheiterte Ableitung bleibt nicht im Speicher haengen.
  real.then<void>((_) {}, onError: (Object _) {
    if (identical(_memo[memoKey], real)) _memo.remove(memoKey);
  });
  // Immer eine Kopie: niemand soll die geteilten Bytes veraendern koennen.
  return Uint8List.fromList(await real);
}

/// Installiert die Speicher-Ableitung fuer diese Testdatei und nimmt sie am
/// Ende wieder weg.
void useMemoizedKeyDerivation() {
  setUpAll(() {
    UltracipherApp.rootDerivation = _memoized;
  });
  tearDownAll(() {
    UltracipherApp.rootDerivation = null;
  });
}

/// `R` fuer [passphrase] (derselbe Wert wie `UltracipherApp.deriveRoot`),
/// ueber denselben Speicher. Zaehlt nicht in [rootDerivationCount].
Future<Uint8List> memoizedRoot(String passphrase) async {
  // Auch vor dem ersten app.init() benutzbar (z. B. in setUpAll).
  var before = rootDerivationCount;
  var root = await _memoized(passphraseBytes(passphrase));
  rootDerivationCount = before;
  return root;
}
