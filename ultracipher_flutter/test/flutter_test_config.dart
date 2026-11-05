// Gilt für jede Testdatei: ohne diese Naht wählte `flutter test` (VM) den
// Speicher mit path_provider und scheiterte am fehlenden Platform-Channel.
// Jede init() bekommt einen frischen Fake, mehrere "Geräte" in einem Test
// bleiben so getrennt. Neustart-Tests setzen die Factory auf einen
// FakeLocalStore über derselben FakeLocalDisk.
//
// Kein dart:io (die Datei läuft auch in den Chrome-Läufen).
import 'dart:async';

import 'package:ultracipher_flutter/src/core.dart';

import 'fake_local_store.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  UltracipherApp.localStoreFactory = () async => FakeLocalStore();
  await testMain();
}
