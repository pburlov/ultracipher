// Die Signatur der angezeigten Liste (entriesSignature) darf kein Label
// enthalten, weil der Screen-State sie dauerhaft haelt (sonst liegen alle
// Labels als Strings im RAM, siehe ObfuscatedString). Sie muss trotzdem jede
// sichtbare Aenderung durch einen Merge in Place erkennen.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultracipher_flutter/src/database_loaded.dart';
import 'package:ultracipher_flutter/src/model/model.dart';

const _label = 'geheimes-label-4711';
const _t0 = '2024-03-01T08:00:00.000';
const _td = '2024-03-01T09:00:00.000';
const _t1 = '2024-03-01T10:00:00.000';
const _t2 = '2024-03-02T10:00:00.000';
const _t3 = '2024-03-03T10:00:00.000';

UltracipherDatabase _db(String label, String time) => UltracipherDatabase()
  ..addEntry(
      entry: VersionedEntry('id-1')
        ..addNewVersion(Entry(label: label, createTime: time)));

List<Object?> _sig(UltracipherDatabase db) =>
    entriesSignature(db, db.getEntries());

void main() {
  test('the signature holds no label text', () {
    var sig = _sig(_db(_label, _t1));
    for (var part in sig) {
      expect(part.toString(), isNot(contains(_label)));
    }
  });

  test('a merged-in new version changes the signature', () {
    var mine = _db('alt', _t1);
    var before = _sig(mine);
    mine.merge(_db(_label, _t2));
    expect(listEquals(_sig(mine), before), isFalse);
  });

  test('a merge without news keeps the signature', () {
    var mine = _db('alt', _t1);
    var before = _sig(mine);
    mine.merge(_db('alt', _t1));
    expect(listEquals(_sig(mine), before), isTrue);
  });

  test('a merged-in new entry changes the signature', () {
    var mine = _db('alt', _t1);
    var before = _sig(mine);
    mine.merge(UltracipherDatabase()
      ..addEntry(
          entry: VersionedEntry('id-2')
            ..addNewVersion(Entry(label: _label, createTime: _t2))));
    expect(listEquals(_sig(mine), before), isFalse);
  });

  // Nur die createTime des Kopfes trennt hier vorher und nachher: Anzahl der
  // Versionen (2) und Datenbankzeit (_t3, vom zweiten Eintrag) bleiben gleich.
  test('a newer head with unchanged count and database time changes the '
      'signature', () {
    var mine = UltracipherDatabase()
      ..addEntry(
          entry: VersionedEntry('id-1')
            ..addNewVersion(Entry(label: 'X', createTime: _t0))
            ..addNewVersion(Entry(label: 'A', createTime: _t1)))
      ..addEntry(
          entry: VersionedEntry('id-2')
            ..addNewVersion(Entry(label: 'Y', createTime: _t3)));
    var before = _sig(mine);
    // Die Loeschung (_td) verwirft X (_t0); A bleibt, B (_t2) wird neuer Kopf.
    mine.merge(UltracipherDatabase()
      ..deleteEntry(VersionedEntry('id-1'), deletedAt: DateTime.parse(_td))
      ..addEntry(
          entry: VersionedEntry('id-1')
            ..addNewVersion(Entry(label: 'B', createTime: _t2))));
    var e = mine.getEntryWhitId('id-1')!;
    expect(e.versions.length, 2);
    expect(e.latestEntry!.label, 'B');
    expect(mine.lastChangedTime, DateTime.parse(_t3));
    expect(listEquals(_sig(mine), before), isFalse);
  });
}
