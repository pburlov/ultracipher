// Der Fake muss denselben Vertrag erfuellen wie der echte Speicher.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ultracipher_flutter/src/local_store/local_store.dart';

import 'fake_local_store.dart';
import 'local_store_contract.dart';

class _FakeHarness implements LocalStoreHarness {
  final disk = FakeLocalDisk();

  @override
  Future<LocalDatabaseStore> open() async {
    final store = FakeLocalStore(disk);
    await store.open();
    return store;
  }

  @override
  void setFailing(LocalDatabaseStore store, bool failing) {
    final fake = store as FakeLocalStore;
    fake.failWrites = failing ? LocalStoreErrorKind.full : null;
    fake.failRemoves = failing ? LocalStoreErrorKind.full : null;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  group('FakeLocalStore', () {
    runLocalStoreContract(() async => _FakeHarness());

    test('persist jobs run one at a time, in call order (FIFO)', () async {
      final fake = FakeLocalStore();
      await fake.open();
      final gate = fake.persistGate = Completer<void>();
      final f1 = fake.write('nameA', Uint8List.fromList([1]));
      final f2 = fake.write('nameB', Uint8List.fromList([2]));
      final f3 = fake.remove('nameA');
      await Future<void>.delayed(Duration.zero);
      // Der erste Auftrag haengt am Gate; die anderen duerfen nicht anlaufen.
      expect(fake.maxConcurrent, 1);
      expect(fake.disk.main, isEmpty);
      fake.persistGate = null;
      gate.complete();
      await Future.wait([f1, f2, f3]);
      expect(fake.maxConcurrent, 1);
      expect(fake.disk.main.keys, ['nameB']);
      expect(fake.disk.bak, isEmpty);
    });
  });
}
