// Ergaenzende Model-Tests, die model_test.dart nicht abdeckt:
//
//  - Idempotenz von UltracipherDatabase.merge: ein spaeterer Conflict-Retry
//    (erneutes Abrufen und Mergen "derselben" Remote-Datenbank) darf keine
//    Versionen oder Eintraege duplizieren.
//  - UltracipherDatabase.cleanUp mit dem DEFAULT-Schwellenwert (365 Tage fuer
//    die Loeschliste), isoliert von dem, was model_test.dart bereits (mit
//    abweichenden, expliziten Schwellenwerten) abdeckt.
//  - Versions-Vereinigung und Loeschliste (Schritt 2 des Local-First-Plans):
//    beidseitige Bearbeitung, Kommutativitaet, Assoziativitaet, Idempotenz,
//    Loeschen gegen Bearbeiten, hasSameContentAs, keine geteilten
//    Objekte, Undo von CsvReplacement liegt in csv_import_export_test.dart.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ultracipher_flutter/src/model/model.dart';

const String _t1 = '2024-03-01T10:00:00.000';
const String _t2 = '2024-03-02T10:00:00.000';
const String _t3 = '2024-03-03T10:00:00.000';

Entry _v(String label, String createTime, {String content = 'c'}) =>
    Entry(label: label, tags: 't', content: content, createTime: createTime);

UltracipherDatabase _singleEntryDb(String id, List<Entry> versions) {
  var entry = VersionedEntry(id);
  for (var v in versions) {
    entry.addNewVersion(v);
  }
  var db = UltracipherDatabase();
  db.addEntry(entry: entry);
  return db;
}

// Unabhaengige Kopie ueber die oeffentliche JSON-API; teilt keine Objekte.
UltracipherDatabase _copyOf(UltracipherDatabase db) =>
    UltracipherDatabase.fromJson(jsonDecode(jsonEncode(db.toJson())));

// Inhalt als id -> sortierte createTime-Strings (Reihenfolge der Eintraege egal).
Map<dynamic, List<String>> _signature(UltracipherDatabase db) {
  var result = <dynamic, List<String>>{};
  for (var e in db.allEntries) {
    expect(result.containsKey(e.id), isFalse, reason: 'doppelte id ${e.id}');
    result[e.id] = e.versions.map((v) => v.createTime).toList()..sort();
  }
  return result;
}

List<String> _sortedTimes(VersionedEntry e) =>
    e.versions.map((v) => v.createTime).toList()..sort();

// Beispiel A: 'x' wird auf A bearbeitet (t2), 'nur-a' existiert nur auf A.
UltracipherDatabase _mixedA() {
  var db = _singleEntryDb('x', [_v('gemeinsam', _t1), _v('a-neu', _t2)]);
  db.addEntry(entry: VersionedEntry('nur-a')..addNewVersion(_v('nur-a', _t1)));
  return db;
}

// Beispiel B: 'x' wird auf B bearbeitet (t3, neueste), 'nur-b' existiert nur auf B.
UltracipherDatabase _mixedB() {
  var db = _singleEntryDb('x', [_v('gemeinsam', _t1), _v('b-neu', _t3)]);
  db.addEntry(entry: VersionedEntry('nur-b')..addNewVersion(_v('nur-b', _t2)));
  return db;
}

UltracipherDatabase _buildRemoteWithSharedEntry() {
  // Baut jedes Mal eine NEUE, aber inhaltlich identische Instanz -- so wie
  // ein erneuter Server-Fetch eine neue UltracipherDatabase liefert, auch
  // wenn sich der Inhalt seit dem letzten Fetch nicht geaendert hat.
  var remote = UltracipherDatabase();
  var entry = VersionedEntry('shared-id');
  entry.addNewVersion(Entry(
      label: 'r0',
      tags: 't0',
      content: 'c0',
      createTime: DateTime(2020, 2, 1).toIso8601String()));
  entry.addNewVersion(Entry(
      label: 'r1',
      tags: 't1',
      content: 'c1',
      createTime: DateTime(2020, 3, 1).toIso8601String()));
  remote.addEntry(entry: entry);
  return remote;
}

void main() {
  test('UltracipherDatabase.merge is idempotent for repeated merges of the '
      'same remote state (matters for a conflict-retry loop)', () {
    var local = UltracipherDatabase();
    local.addEntry()
      .addNewVersion(Entry(
          label: 'local-only',
          tags: 't',
          content: 'c',
          createTime: DateTime(2020, 1, 1).toIso8601String()));

    local.merge(_buildRemoteWithSharedEntry());
    var afterFirstMerge = local.toJson();

    // Ein spaeterer Retry mergt eine FRISCHE Instanz mit identischem
    // Inhalt (kein Objekt-Alias) -- genau das wuerde ein Conflict-Retry
    // um saveDatabase herum tun. Das Ergebnis muss unveraendert bleiben:
    // keine doppelten Versionen, keine doppelten Eintraege.
    local.merge(_buildRemoteWithSharedEntry());
    var afterSecondMerge = local.toJson();

    expect(afterSecondMerge, equals(afterFirstMerge));
    expect(local.allEntries.length, equals(2));
    expect(local.getEntryWhitId('shared-id')!.versions.length, equals(2));
  });

  test(
      'UltracipherDatabase.cleanUp drops deletion-list entries older than the '
      'default 365 days and keeps younger ones (and live entries)', () {
    var db = UltracipherDatabase();
    var oldGone = db.addEntry()
      ..addNewVersion(Entry(label: 'old', tags: '', content: 'x'));
    var youngGone = db.addEntry()
      ..addNewVersion(Entry(label: 'young', tags: '', content: 'y'));
    var liveEntry = db.addEntry()
      ..addNewVersion(Entry(label: 'live', tags: '', content: 'z'));
    db.deleteEntry(oldGone,
        deletedAt: DateTime.now().subtract(Duration(days: 366)));
    db.deleteEntry(youngGone,
        deletedAt: DateTime.now().subtract(Duration(days: 364)));

    db.cleanUp(); // Standard-Frist: 365 Tage.

    expect(db.deletions.keys, equals([youngGone.id]));
    expect(db.allEntries.map((e) => e.id), equals([liveEntry.id]));
  });

  // ---- Versions-Vereinigung (Sicherheitsnetz vor dem Umbau auf die Loeschliste) ----

  test(
      'beidseitige Bearbeitung desselben Eintrags: alle Versionen bleiben, '
      'die neueste steht oben (in beide Richtungen)', () {
    var ab = _singleEntryDb('x', [_v('gemeinsam', _t1), _v('a-neu', _t2)])
      ..merge(_singleEntryDb('x', [_v('gemeinsam', _t1), _v('b-neu', _t3)]));
    var ba = _singleEntryDb('x', [_v('gemeinsam', _t1), _v('b-neu', _t3)])
      ..merge(_singleEntryDb('x', [_v('gemeinsam', _t1), _v('a-neu', _t2)]));

    for (var db in [ab, ba]) {
      expect(db.allEntries.length, equals(1));
      var entry = db.getEntryWhitId('x')!;
      expect(_sortedTimes(entry), equals([_t1, _t2, _t3]));
      expect(entry.versions.length, equals(3));
      expect(entry.latestEntry!.createTime, equals(_t3));
      expect(entry.latestEntry!.label, equals('b-neu'));
    }
  });

  test('Eintrag nur auf einer Seite bleibt in beiden Richtungen erhalten; '
      'andere Eintraege bleiben unberuehrt', () {
    var expected = {
      'nur-a': [_t1],
      'nur-b': [_t2],
      'x': [_t1, _t2, _t3],
    };
    var ab = _mixedA()..merge(_mixedB());
    var ba = _mixedB()..merge(_mixedA());

    expect(_signature(ab), equals(expected));
    expect(_signature(ba), equals(expected));
    expect(ab.getEntryWhitId('nur-a')!.latestEntry!.label, equals('nur-a'));
    expect(ba.getEntryWhitId('nur-a')!.latestEntry!.label, equals('nur-a'));
    expect(ab.getEntryWhitId('nur-b')!.latestEntry!.label, equals('nur-b'));
    expect(ba.getEntryWhitId('nur-b')!.latestEntry!.label, equals('nur-b'));
  });

  test('Idempotenz: a.merge(a) und a.merge(Kopie von a) aendern nichts', () {
    var pristine = _signature(_mixedA());
    var self = _mixedA();
    self.merge(self);
    expect(_signature(self), equals(pristine));

    var a = _mixedA();
    a.merge(_copyOf(a));
    expect(_signature(a), equals(pristine));
    expect(a.getEntryWhitId('x')!.latestEntry!.label, equals('a-neu'));
  });

  test('Kommutativitaet (Inhalt): a.merge(b) und b.merge(a) haben gleiche '
      'IDs und gleiche createTime-Mengen je Eintrag', () {
    var ab = _mixedA()..merge(_mixedB());
    var ba = _mixedB()..merge(_mixedA());

    expect(_signature(ab), equals(_signature(ba)));
    expect(ab.getEntryWhitId('x')!.latestEntry!.label,
        equals(ba.getEntryWhitId('x')!.latestEntry!.label));
  });

  test('Assoziativitaet fuer drei Datenbanken: (A+B)+C und A+(B+C) haben '
      'gleichen Inhalt', () {
    UltracipherDatabase dbA() => _singleEntryDb(
        'x', [_v('a1', _t1)])
      ..addEntry(entry: VersionedEntry('p')..addNewVersion(_v('pa', _t1)));
    UltracipherDatabase dbB() => _singleEntryDb(
        'x', [_v('b2', _t2)])
      ..addEntry(entry: VersionedEntry('q')..addNewVersion(_v('qb', _t2)));
    UltracipherDatabase dbC() => _singleEntryDb(
        'x', [_v('c3', _t3)])
      ..addEntry(entry: VersionedEntry('p')..addNewVersion(_v('pc', _t2)))
      ..addEntry(entry: VersionedEntry('r')..addNewVersion(_v('rc', _t3)));

    var left = _copyOf(dbA())..merge(_copyOf(dbB()));
    left.merge(_copyOf(dbC()));

    var bc = _copyOf(dbB())..merge(_copyOf(dbC()));
    var right = _copyOf(dbA())..merge(bc);

    expect(_signature(left), equals(_signature(right)));
    expect(_signature(left), equals({
      'x': [_t1, _t2, _t3],
      'p': [_t1, _t2],
      'q': [_t2],
      'r': [_t3],
    }));
  });

  test(
      'Gleiche createTime mit verschiedenem Inhalt: beide Versionen bleiben, '
      'bei gleicher Zeit steht die eigene (lokale) Version oben', () {
    UltracipherDatabase a() =>
        _singleEntryDb('x', [_v('links', _t1, content: 'a')]);
    UltracipherDatabase b() =>
        _singleEntryDb('x', [_v('rechts', _t1, content: 'b')]);

    var ab = a()..merge(b());
    var ba = b()..merge(a());

    for (var db in [ab, ba]) {
      var entry = db.getEntryWhitId('x')!;
      expect(entry.versions.length, equals(2));
      expect(entry.versions.map((v) => v.label).toSet(),
          equals({'links', 'rechts'}));
    }
    expect(ab.getEntryWhitId('x')!.latestEntry!.label, equals('links'));
    expect(ab.getEntryWhitId('x')!.versions[1].label, equals('rechts'));
    expect(ba.getEntryWhitId('x')!.latestEntry!.label, equals('rechts'));
    expect(ba.getEntryWhitId('x')!.versions[1].label, equals('links'));

    // Als Menge sind beide Ergebnisse gleich, ein weiterer Merge aendert nichts.
    expect(ab.hasSameContentAs(ba), isTrue);
    expect(ba.hasSameContentAs(ab), isTrue);
    ab.merge(b());
    ba.merge(a());
    expect(ab.getEntryWhitId('x')!.versions.length, equals(2));
    expect(ba.getEntryWhitId('x')!.versions.length, equals(2));
    expect(ab.getEntryWhitId('x')!.latestEntry!.label, equals('links'));
    expect(ab.hasSameContentAs(ba), isTrue);
  });

  test(
      'Zeitstempel mit und ohne Offset (heutiges Verhalten, nur dokumentiert): '
      'beide Versionen bleiben, latestEntry ist der spaetere Zeitpunkt', () {
    const ohne = '2024-05-01T10:00:00.000';
    const mitZ = '2024-05-01T10:00:00.000Z';
    // Ohne Offset ist die Zeit lokal, mit Z UTC. Die Reihenfolge haengt also
    // von der Zeitzone des Rechners ab; verglichen wird der Zeitpunkt.
    var later = [DateTime.parse(ohne), DateTime.parse(mitZ)]
        .reduce((x, y) => x.isAfter(y) ? x : y);

    var ab = _singleEntryDb('x', [_v('ohne', ohne)])
      ..merge(_singleEntryDb('x', [_v('mit', mitZ)]));
    var ba = _singleEntryDb('x', [_v('mit', mitZ)])
      ..merge(_singleEntryDb('x', [_v('ohne', ohne)]));

    for (var db in [ab, ba]) {
      var entry = db.getEntryWhitId('x')!;
      // Dedupe erfolgt ueber den String, nicht ueber den Zeitpunkt.
      expect(_sortedTimes(entry), equals([ohne, mitZ]..sort()));
      expect(entry.latestEntry!.createDateTime.isAtSameMomentAs(later), isTrue);
    }
  });

  test('Sortierung nach Zeitpunkt, nicht nach String: Offset gemischt', () {
    // 12:00 mit +02:00 ist 10:00 UTC, 10:30 UTC ist also spaeter. Als String
    // waere '12:00...' der groessere Wert.
    const plusZwei = '2024-05-01T12:00:00.000+02:00';
    const utc1030 = '2024-05-01T10:30:00.000Z';
    var db = _singleEntryDb('x', [_v('a', plusZwei), _v('b', utc1030)]);
    var entry = db.getEntryWhitId('x')!;
    expect(entry.latestEntry!.createTime, utc1030);
    expect(entry.latestChangeTime, equals(DateTime.parse(utc1030)));
  });

  test('Sortierung nach Zeitpunkt, nicht nach String: Bruchteile von Sekunden',
      () {
    // Als String ist '10:00:00Z' groesser als '10:00:00.500Z' ('Z' > '.'),
    // zeitlich ist 10:00:00.500 aber spaeter.
    const ganz = '2024-05-01T10:00:00Z';
    const halb = '2024-05-01T10:00:00.500Z';
    var db = _singleEntryDb('x', [_v('ganz', ganz), _v('halb', halb)]);
    expect(db.getEntryWhitId('x')!.latestEntry!.createTime, halb);
  });

  test('Merge teilt keine mutablen Objekte: eine neue Version in a aendert '
      'den Eintrag in b nicht', () {
    var b = _singleEntryDb('x', [_v('b', _t1)]);
    var a = UltracipherDatabase();
    a.merge(b);

    a.getEntryWhitId('x')!.addNewVersion(_v('a-neu', _t2));

    expect(b.getEntryWhitId('x')!.versions.length, equals(1));
    expect(b.getEntryWhitId('x')!.latestEntry!.label, equals('b'));
  });

  test('Merge teilt auch beim Zusammenfuehren zweier vorhandener Eintraege '
      'keine Versionen: Aenderung an a veraendert b nicht', () {
    var b = _singleEntryDb('x', [_v('b', _t2)]);
    var a = _singleEntryDb('x', [_v('a', _t1)]);
    a.merge(b);

    a.getEntryWhitId('x')!.versions.first.label = 'veraendert';
    expect(b.getEntryWhitId('x')!.latestEntry!.label, equals('b'));
    expect(b.getEntryWhitId('x')!.versions.length, equals(1));
  });

  test('merge veraendert die andere Datenbank nicht (hasSameContentAs mit '
      'Vorher-Kopie)', () {
    UltracipherDatabase build() {
      var b = _singleEntryDb('x', [_v('b', _t1), _v('b2', _t2)]);
      b.addEntry(entry: VersionedEntry('nur-b')..addNewVersion(_v('y', _t2)));
      b.addEntry(entry: VersionedEntry('weg')..addNewVersion(_v('w', _t1)));
      b.deleteEntry(b.getEntryWhitId('weg')!, deletedAt: DateTime.utc(2024, 3, 2));
      return b;
    }

    var b = build();
    var before = _copyOf(b);
    var a = _singleEntryDb('x', [_v('a', _t3)])
      ..addEntry(entry: VersionedEntry('weg')..addNewVersion(_v('a-weg', _t1)))
      ..merge(b);

    expect(b.hasSameContentAs(before), isTrue);
    expect(jsonEncode(b.toJson()), equals(jsonEncode(before.toJson())));
    expect(a.allEntries.map((e) => e.id).toSet(), equals({'x', 'nur-b'}));
  });

  test('keine geteilten Objekte, Richtung a -> b: Aenderungen an a '
      '(neue Version, Setter) lassen b unveraendert, fuer nur-remote-Eintraege '
      'und Eintraege auf beiden Seiten', () {
    var b = _singleEntryDb('beide', [_v('b-beide', _t1)])
      ..addEntry(entry: VersionedEntry('nur-b')..addNewVersion(_v('b-nur', _t1)));
    var before = _copyOf(b);
    var a = _singleEntryDb('beide', [_v('a-beide', _t2)])..merge(b);

    for (var id in ['beide', 'nur-b']) {
      var entry = a.getEntryWhitId(id)!;
      entry.addNewVersion(_v('neu', _t3));
      for (var v in entry.versions) {
        v.label = 'gesetzt';
        v.tags = 'gesetzt';
        v.content = 'gesetzt';
      }
    }
    expect(b.hasSameContentAs(before), isTrue);
    expect(b.getEntryWhitId('beide')!.versions.single.label, equals('b-beide'));
    expect(b.getEntryWhitId('nur-b')!.versions.single.label, equals('b-nur'));
    expect(b.getEntryWhitId('nur-b')!.versions.single.content, equals('c'));
  });

  test('keine geteilten Objekte, Richtung b -> a: spaetere Aenderungen an b '
      'veraendern a nicht', () {
    var b = _singleEntryDb('beide', [_v('b-beide', _t1)])
      ..addEntry(entry: VersionedEntry('nur-b')..addNewVersion(_v('b-nur', _t1)));
    var a = _singleEntryDb('beide', [_v('a-beide', _t2)])..merge(b);
    var snapshot = _copyOf(a);

    for (var id in ['beide', 'nur-b']) {
      var entry = b.getEntryWhitId(id)!;
      entry.addNewVersion(_v('neu', _t3));
      for (var v in entry.versions) {
        v.label = 'gesetzt';
        v.content = 'gesetzt';
      }
    }
    b.deleteEntry(b.getEntryWhitId('nur-b')!);

    expect(a.hasSameContentAs(snapshot), isTrue);
    expect(a.getEntryWhitId('nur-b')!.versions.single.label, equals('b-nur'));
    expect(a.getEntryWhitId('beide')!.versions.map((v) => v.label).toSet(),
        equals({'a-beide', 'b-beide'}));
    expect(a.deletions, isEmpty);
  });

  // ---- cleanUp mit Standard-Schwelle: leere Eintraege ----

  test('cleanUp() mit Standard-Schwelle entfernt leere Eintraege sofort, '
      'auch ohne Tombstone', () {
    var db = UltracipherDatabase();
    db.addEntry(); // ohne jede Version
    db.addEntry().addNewVersion(
        Entry(label: '', tags: '', content: '', createTime: _t1));

    expect(db.allEntries.length, equals(2));
    db.cleanUp();
    expect(db.allEntries, isEmpty);
  });

  // ---- Loeschliste ----

  final deletedT = DateTime.utc(2024, 3, 2, 10); // zwischen _t1 und _t3 (UTC)

  // Zeitpunkte in UTC, damit der Vergleich nicht von der Zeitzone abhaengt.
  const String u1 = '2024-03-01T10:00:00.000Z';
  const String u2 = '2024-03-02T10:00:00.000Z';
  const String u3 = '2024-03-03T10:00:00.000Z';

  UltracipherDatabase withDeleted(String id, DateTime at,
      {List<Entry>? versions}) {
    var db = _singleEntryDb(id, versions ?? [_v('v', u1)]);
    db.deleteEntry(db.getEntryWhitId(id)!, deletedAt: at);
    return db;
  }

  test('Loeschung nur lokal: nach merge in beiden Richtungen geloescht, '
      'id in der Liste', () {
    UltracipherDatabase local() => withDeleted('x', DateTime.utc(2024, 3, 5));
    UltracipherDatabase remote() => _singleEntryDb('x', [_v('v', u1)]);

    var lr = local()..merge(remote());
    var rl = remote()..merge(local());

    for (var db in [lr, rl]) {
      expect(db.allEntries, isEmpty);
      expect(db.deletions.keys, equals(['x']));
    }
    expect(lr.hasSameContentAs(rl), isTrue);
  });

  test('Loeschung nur remote: wird in beiden Richtungen uebernommen', () {
    var remote = withDeleted('x', DateTime.utc(2024, 3, 5));
    var local = _singleEntryDb('x', [_v('v', u1)]);
    var other = _singleEntryDb('x', [_v('v', u1)]);

    local.merge(remote);
    remote.merge(other);

    expect(local.allEntries, isEmpty);
    expect(local.deletions.keys, equals(['x']));
    expect(remote.allEntries, isEmpty);
    expect(remote.deletions.keys, equals(['x']));
  });

  test('geloescht bei T1, bearbeitet bei T2 > T1: Eintrag lebt mit den neueren '
      'Versionen, die id bleibt in der Liste (beide Richtungen)', () {
    UltracipherDatabase deleter() => withDeleted('x', deletedT);
    UltracipherDatabase editor() =>
        _singleEntryDb('x', [_v('v', u1), _v('neu', u3)]);

    var de = deleter()..merge(editor());
    var ed = editor()..merge(deleter());

    for (var db in [de, ed]) {
      expect(db.allEntries.length, equals(1));
      var entry = db.getEntryWhitId('x')!;
      // Die alte Version (u1 <= deletedT) ist verworfen.
      expect(_sortedTimes(entry), equals([u3]));
      expect(entry.latestEntry!.label, equals('neu'));
      expect(db.deletions, equals({'x': deletedT}));
    }
    expect(de.hasSameContentAs(ed), isTrue);
  });

  test('bearbeitet bei T1, geloescht bei T2 > T1: geloescht (beide Richtungen)',
      () {
    UltracipherDatabase deleter() => withDeleted('x', DateTime.utc(2024, 3, 5));
    UltracipherDatabase editor() =>
        _singleEntryDb('x', [_v('v', u1), _v('neu', u3)]);

    var de = deleter()..merge(editor());
    var ed = editor()..merge(deleter());

    for (var db in [de, ed]) {
      expect(db.allEntries, isEmpty);
      expect(db.deletions.keys, equals(['x']));
    }
  });

  test('gleiche Zeit von Version und Loeschung: geloescht', () {
    var deleter = withDeleted('x', DateTime.utc(2024, 3, 3, 10));
    var editor = _singleEntryDb('x', [_v('neu', u3)]);

    var de = _copyOf(deleter)..merge(editor);
    var ed = _copyOf(editor)..merge(deleter);

    for (var db in [de, ed]) {
      expect(db.allEntries, isEmpty);
      expect(db.deletions.keys, equals(['x']));
    }
  });

  test('Vergleich nach Zeitpunkt, nicht nach Text: Version mit Offset gegen '
      'Loeschung in UTC', () {
    // 11:00+01:00 ist derselbe Zeitpunkt wie 10:00Z -> gleich alt = geloescht.
    var deleter = withDeleted('x', DateTime.utc(2024, 3, 3, 10));
    var editor = _singleEntryDb('x', [_v('neu', '2024-03-03T11:00:00.000+01:00')]);
    var db = _copyOf(editor)..merge(deleter);
    expect(db.allEntries, isEmpty);
  });

  test('Gegenbeispiel aus dem Review: alte Version (A), Loeschung (B), neuere '
      'Version (C) ergeben in allen Reihenfolgen und Klammerungen dieselbe '
      'Menge', () {
    UltracipherDatabase a() => _singleEntryDb('x', [_v('alt', u1)]);
    UltracipherDatabase b() => withDeleted('x', deletedT);
    UltracipherDatabase c() => _singleEntryDb('x', [_v('neu', u3)]);

    UltracipherDatabase m(UltracipherDatabase x, UltracipherDatabase y) =>
        _copyOf(x)..merge(y);
    var fs = [a, b, c];
    var results = <UltracipherDatabase>[];
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        for (var k = 0; k < 3; k++) {
          if ({i, j, k}.length != 3) continue;
          results.add(m(m(fs[i](), fs[j]()), fs[k]()));
          results.add(m(fs[i](), m(fs[j](), fs[k]())));
        }
      }
    }
    expect(results.length, equals(12));
    for (var r in results) {
      expect(_signature(r), equals({'x': [u3]}));
      expect(r.deletions, equals({'x': deletedT}));
      expect(r.hasSameContentAs(results.first), isTrue);
    }
  });

  test('3 Geraete mit Bearbeiten, Loeschen, Bearbeiten: alle Permutationen und '
      'Klammerungen ergeben denselben Inhalt', () {
    // Auf allen drei Geraeten gibt es x mit v@u1.
    UltracipherDatabase a() =>
        _singleEntryDb('x', [_v('v', u1), _v('a-edit', u2)]); // bearbeitet
    UltracipherDatabase b() => withDeleted('x', DateTime.utc(2024, 3, 2, 12),
        versions: [_v('v', u1), _v('a-edit', u2)]); // geloescht nach u2
    UltracipherDatabase c() => _singleEntryDb(
        'x', [_v('v', u1), _v('c-edit', u3)]); // bearbeitet nach der Loeschung
    UltracipherDatabase m(UltracipherDatabase x, UltracipherDatabase y) =>
        _copyOf(x)..merge(y);

    var fs = [a, b, c];
    var results = <UltracipherDatabase>[];
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        for (var k = 0; k < 3; k++) {
          if ({i, j, k}.length != 3) continue;
          results.add(m(m(fs[i](), fs[j]()), fs[k]()));
          results.add(m(fs[i](), m(fs[j](), fs[k]())));
        }
      }
    }
    for (var r in results) {
      expect(_signature(r), equals({'x': [u3]}));
      expect(r.getEntryWhitId('x')!.latestEntry!.label, equals('c-edit'));
      expect(r.deletions.keys, equals(['x']));
      expect(r.hasSameContentAs(results.first), isTrue);
    }
  });

  test('Idempotenz mit Loeschliste und Bearbeitung nach der Loeschung', () {
    var db = _singleEntryDb('x', [_v('v', u1), _v('neu', u3)])
      ..restoreDeletions({'x': deletedT, 'g': DateTime.utc(2024, 1, 1)});
    // restoreDeletions wendet die Regel nicht an; ein Merge mit sich selbst schon.
    var merged = _copyOf(db)..merge(db);
    expect(_signature(merged), equals({'x': [u3]}));
    var again = _copyOf(merged)..merge(merged);
    expect(again.hasSameContentAs(merged), isTrue);
    expect((_copyOf(merged)..merge(_copyOf(merged))).hasSameContentAs(merged),
        isTrue);
  });

  test('deleteEntry, dann Bearbeitung/Merge: Loeschliste bleibt, nur neuere '
      'Versionen beleben den Eintrag', () {
    var db = _singleEntryDb('x', [_v('v', u1)]);
    var copyBefore = _copyOf(db);
    db.deleteEntry(db.getEntryWhitId('x')!, deletedAt: deletedT);
    expect(db.allEntries, isEmpty);

    // Gegenseite hat nur die alte Version: bleibt geloescht.
    db.merge(copyBefore);
    expect(db.allEntries, isEmpty);
    expect(db.deletions, equals({'x': deletedT}));

    // Bearbeitung danach (anderes Geraet) belebt den Eintrag, die id bleibt.
    db.merge(_singleEntryDb('x', [_v('v', u1), _v('danach', u3)]));
    expect(_signature(db), equals({'x': [u3]}));
    expect(db.deletions, equals({'x': deletedT}));

    // addEntry mit einem Eintrag, dessen Versionen alle <= deletedAt sind.
    var other = UltracipherDatabase()
      ..restoreDeletions({'y': deletedT});
    other.addEntry(entry: VersionedEntry('y')..addNewVersion(_v('y', u1)));
    expect(other.allEntries, isEmpty);
    other.addEntry(
        entry: VersionedEntry('y')
          ..addNewVersion(_v('y', u1))
          ..addNewVersion(_v('y2', u3)));
    expect(_signature(other), equals({'y': [u3]}));
  });

  test('fromJson wendet die Loeschliste an: nur neuere Versionen bleiben', () {
    var db = UltracipherDatabase.fromJson({
      'entries': [
        {
          'id': 'x',
          'versions': [
            {'label': 'alt', 'tags': '', 'time': u1, 'content': 'c'},
            {'label': 'neu', 'tags': '', 'time': u3, 'content': 'c'},
          ]
        },
        {
          'id': 'y',
          'versions': [
            {'label': 'alt', 'tags': '', 'time': u1, 'content': 'c'},
          ]
        }
      ],
      'deleted': [
        {'id': 'x', 'time': deletedT.toIso8601String()},
        {'id': 'y', 'time': deletedT.toIso8601String()},
      ],
    });
    expect(_signature(db), equals({'x': [u3]}));
    expect(db.deletions.keys.toSet(), equals({'x', 'y'}));
  });

  test('cleanUp entfernt nur alte Loeschlisteneintraege, nie die von '
      'Bearbeitungen betroffenen jungen', () {
    var db = _singleEntryDb('x', [_v('v', u1), _v('neu', u3)])
      ..restoreDeletions({
        'x': DateTime.now().toUtc().subtract(Duration(days: 10)),
        'alt': DateTime.now().toUtc().subtract(Duration(days: 400)),
      });
    db.cleanUp();
    expect(db.deletions.keys, equals(['x']));
    expect(db.allEntries.length, equals(1));
  });

  test('Loeschlisten werden vereinigt, je id gewinnt der spaetere Zeitpunkt', () {
    var a = UltracipherDatabase();
    var b = UltracipherDatabase();
    a.restoreDeletions({'p': DateTime.utc(2024, 1, 1), 'q': DateTime.utc(2024, 5, 1)});
    b.restoreDeletions({'p': DateTime.utc(2024, 2, 1), 'r': DateTime.utc(2024, 3, 1)});

    var ab = _copyOf(a)..merge(b);
    var ba = _copyOf(b)..merge(a);

    var expected = {
      'p': DateTime.utc(2024, 2, 1),
      'q': DateTime.utc(2024, 5, 1),
      'r': DateTime.utc(2024, 3, 1),
    };
    expect(ab.deletions, equals(expected));
    expect(ba.deletions, equals(expected));
  });

  test('Kommutativitaet, Assoziativitaet und Idempotenz inklusive Loeschliste',
      () {
    UltracipherDatabase a() => withDeleted('x', deletedT)
      ..addEntry(entry: VersionedEntry('p')..addNewVersion(_v('pa', u1)));
    UltracipherDatabase b() => _singleEntryDb('x', [_v('v', u1), _v('b', u3)])
      ..addEntry(entry: VersionedEntry('q')..addNewVersion(_v('qb', u1)));
    UltracipherDatabase c() {
      var db = _singleEntryDb('p', [_v('pc', u1)]);
      db.deleteEntry(db.getEntryWhitId('p')!, deletedAt: DateTime.utc(2024, 3, 4));
      db.addEntry(entry: VersionedEntry('x')..addNewVersion(_v('v', u1)));
      return db;
    }

    UltracipherDatabase m(UltracipherDatabase x, UltracipherDatabase y) =>
        _copyOf(x)..merge(y);

    var dbs = {'a': a, 'b': b, 'c': c};
    for (var x in dbs.values) {
      for (var y in dbs.values) {
        expect(m(x(), y()).hasSameContentAs(m(y(), x())), isTrue);
      }
      expect(m(x(), x()).hasSameContentAs(x()), isTrue);
    }
    // Assoziativitaet in allen Gruppierungen und Reihenfolgen.
    var orders = [
      [a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]
    ];
    var results = <UltracipherDatabase>[];
    for (var o in orders) {
      results.add(m(m(o[0](), o[1]()), o[2]()));
      results.add(m(o[0](), m(o[1](), o[2]())));
    }
    for (var r in results) {
      expect(r.hasSameContentAs(results.first), isTrue);
    }
    // Der Merge ist idempotent: ein weiterer Merge aendert nichts.
    expect(m(results.first, a()).hasSameContentAs(results.first), isTrue);
  });

  test('latestChangeTime ist das Maximum ueber alle Versionen, auch wenn die '
      'Liste aus fromJson nicht sortiert ist', () {
    var db = UltracipherDatabase.fromJson({
      'entries': [
        {
          'id': 'x',
          'versions': [
            {'label': 'a', 'tags': '', 'time': u1, 'content': 'c'},
            {'label': 'b', 'tags': '', 'time': u3, 'content': 'c'},
            {'label': 'c', 'tags': '', 'time': u2, 'content': 'c'},
          ]
        }
      ]
    });
    expect(db.getEntryWhitId('x')!.latestChangeTime, equals(DateTime.parse(u3)));
    expect(db.lastChangedTime, equals(DateTime.parse(u3)));
  });

  test('cleanUp: leerer Eintrag wird mit jetzt (UTC) in die Liste eingetragen, '
      'auch mit alter Version', () {
    var db = UltracipherDatabase();
    var withTime = db.addEntry()
      ..addNewVersion(Entry(label: '', tags: '', content: '', createTime: u2));
    var without = db.addEntry();
    var before = DateTime.now().toUtc();
    db.cleanUp();
    expect(db.allEntries, isEmpty);
    for (var id in [withTime.id, without.id]) {
      var t = db.deletions[id]!;
      expect(t.isUtc, isTrue);
      expect(t.isBefore(before.subtract(Duration(minutes: 1))), isFalse);
    }
  });

  test('Dedupe-Schluessel ist kollisionsfrei: NUL in label/tags erzeugt keine '
      'falsche Gleichheit', () {
    // Mit NUL-Trennern waeren ('a\u0000b','') und ('a','b\u0000') gleich.
    var a = _singleEntryDb('x', [
      Entry(label: 'a\u0000b', tags: 'q', content: 'c', createTime: _t1)
    ]);
    var b = _singleEntryDb('x', [
      Entry(label: 'a', tags: 'b\u0000q', content: 'c', createTime: _t1)
    ]);
    expect(a.hasSameContentAs(b), isFalse);
    var merged = _copyOf(a)..merge(b);
    expect(merged.getEntryWhitId('x')!.versions.length, equals(2));
  });

  test('toJson/fromJson-Roundtrip mit Loeschliste', () {
    var db = _singleEntryDb('x', [_v('v', u1)]);
    db.addEntry(entry: VersionedEntry('y')..addNewVersion(_v('w', u2)));
    db.deleteEntry(db.getEntryWhitId('y')!, deletedAt: DateTime.utc(2024, 4, 1, 12));

    var json = jsonDecode(jsonEncode(db.toJson())) as Map<String, dynamic>;
    expect(json['deleted'], equals([
      {'id': 'y', 'time': '2024-04-01T12:00:00.000Z'}
    ]));
    var back = UltracipherDatabase.fromJson(json);
    expect(back.hasSameContentAs(db), isTrue);
    expect(back.toJson(), equals(db.toJson()));
  });

  test('toJson schreibt die Liste immer, leer als []; fehlendes Feld = leer', () {
    var db = UltracipherDatabase();
    expect(db.toJson()['deleted'], equals([]));
    expect(UltracipherDatabase.fromJson({'entries': []}).deletions, isEmpty);
    expect(UltracipherDatabase.fromJson({'entries': [], 'deleted': null}).deletions,
        isEmpty);
  });

  test('fromJson: falsche Typen in deleted -> FormatException', () {
    for (var bad in [
      'x',
      42,
      {'a': 1},
      [42],
      [{'id': 'a'}],
      [{'id': 'a', 'time': 5}],
      [{'id': 'a', 'time': 'kein Datum'}],
    ]) {
      expect(() => UltracipherDatabase.fromJson({'entries': [], 'deleted': bad}),
          throwsFormatException,
          reason: '$bad');
    }
  });

  test('deleteEntry: Eintrag weg, id mit Zeitpunkt in UTC in der Liste', () {
    var db = _singleEntryDb('x', [_v('v', u1)]);
    var before = DateTime.now().toUtc();
    db.deleteEntry(db.getEntryWhitId('x')!);
    var at = db.deletions['x']!;
    expect(db.allEntries, isEmpty);
    expect(at.isUtc, isTrue);
    expect(at.isBefore(before), isFalse);
    expect(db.lastChangedTime.isAtSameMomentAs(at), isTrue);

    // Mit steuerbarer Zeit (auch lokal angegeben) wird UTC gespeichert.
    var db2 = _singleEntryDb('x', [_v('v', u1)]);
    db2.deleteEntry(db2.getEntryWhitId('x')!, deletedAt: DateTime(2024, 6, 1, 12));
    expect(db2.deletions['x']!.isUtc, isTrue);
  });

  test('lastChangedTime: Maximum aus neuesten Versionen und Loeschliste', () {
    var db = _singleEntryDb('x', [_v('v', u1), _v('w', u2)]);
    expect(db.lastChangedTime, equals(DateTime.parse(u2)));
    db.restoreDeletions({'g': DateTime.utc(2024, 3, 9)});
    expect(db.lastChangedTime, equals(DateTime.utc(2024, 3, 9)));
    db.restoreDeletions({'g': DateTime.utc(2024, 3, 1)});
    expect(db.lastChangedTime, equals(DateTime.parse(u2)));
  });

  test('cleanUp: leere Eintraege landen in der Loeschliste und kommen nicht '
      'vom Server zurueck', () {
    var db = UltracipherDatabase();
    var recent =
        DateTime.now().toUtc().subtract(Duration(days: 10)).toIso8601String();
    var empty = db.addEntry()
      ..addNewVersion(
          Entry(label: '', tags: '', content: '', createTime: recent));
    var emptyId = empty.id;
    var remote = UltracipherDatabase()
      ..addEntry(entry: VersionedEntry(emptyId)
        ..addNewVersion(
            Entry(label: '', tags: '', content: '', createTime: recent)));

    db.cleanUp();
    expect(db.allEntries, isEmpty);
    expect(db.deletions.keys, equals([emptyId]));

    db.merge(remote);
    expect(db.allEntries, isEmpty);
  });

  test('hasSameContentAs: gleich, auch bei anderer Reihenfolge', () {
    UltracipherDatabase build(List<String> ids) {
      var db = UltracipherDatabase();
      for (var id in ids) {
        db.addEntry(entry: VersionedEntry(id)..addNewVersion(_v(id, u1)));
      }
      db.restoreDeletions({'g': DateTime.utc(2024, 1, 1)});
      return db;
    }

    expect(build(['a', 'b']).hasSameContentAs(build(['b', 'a'])), isTrue);
  });

  test('hasSameContentAs: ungleich bei fehlendem Eintrag, Inhalt, Loeschliste '
      'und Zeitpunkt', () {
    var base = _singleEntryDb('x', [_v('v', u1)]);

    var extra = _copyOf(base)
      ..addEntry(entry: VersionedEntry('y')..addNewVersion(_v('y', u1)));
    expect(base.hasSameContentAs(extra), isFalse);
    expect(extra.hasSameContentAs(base), isFalse);

    expect(base.hasSameContentAs(_singleEntryDb('z', [_v('v', u1)])), isFalse);

    expect(base.hasSameContentAs(_singleEntryDb('x', [_v('anders', u1)])),
        isFalse);
    expect(base.hasSameContentAs(_singleEntryDb('x', [_v('v', u1, content: 'd')])),
        isFalse);
    expect(base.hasSameContentAs(_singleEntryDb('x', [_v('v', u2)])), isFalse);
    expect(base.hasSameContentAs(_singleEntryDb('x', [_v('v', u1), _v('v', u2)])),
        isFalse);

    var withList = _copyOf(base)..restoreDeletions({'g': DateTime.utc(2024, 1, 1)});
    expect(base.hasSameContentAs(withList), isFalse);
    var otherTime = _copyOf(base)..restoreDeletions({'g': DateTime.utc(2024, 1, 2)});
    expect(withList.hasSameContentAs(otherTime), isFalse);
    expect(withList.hasSameContentAs(_copyOf(withList)), isTrue);
  });

  test('hasSameContentAs: Tie-Break-Unterschied (gleiche Zeit, anderer Inhalt) '
      'ist ungleich; beide Merge-Richtungen sind als Menge gleich', () {
    var a = _singleEntryDb('x', [_v('links', _t1, content: 'a')]);
    var b = _singleEntryDb('x', [_v('rechts', _t1, content: 'b')]);
    expect(a.hasSameContentAs(b), isFalse);
    expect((_copyOf(a)..merge(b)).hasSameContentAs(_copyOf(b)..merge(a)), isTrue);
    expect((_copyOf(a)..merge(b)).hasSameContentAs(a), isFalse);
  });

  // ---- settings-Register (Schritt 6 des Local-First-Plans) ----

  const secret = 'ghp_SECRET_TOKEN_VALUE';
  GithubSettings gh(String token,
          {String owner = 'o', String repo = 'r', String branch = 'main'}) =>
      GithubSettings(token: token, owner: owner, repo: repo, branch: branch);
  var s1 = DateTime.utc(2024, 5, 1, 10);
  var s2 = DateTime.utc(2024, 5, 2, 10);
  var s3 = DateTime.utc(2024, 5, 3, 10);

  UltracipherDatabase withSettings(String entryId, GithubSettings? github,
      DateTime? time) {
    var db = _singleEntryDb(entryId, [_v(entryId, _t1)]);
    if (time != null) db.setSettings(github: github, time: time);
    return db;
  }

  // Alle 6 Reihenfolgen mit beiden Klammerungen; Ergebnis muss immer gleich
  // sein und gleich dem Ergebnis der ersten Reihenfolge.
  void expectLattice(List<UltracipherDatabase> dbs) {
    expect(dbs.length, equals(3));
    var perms = [
      [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]
    ];
    DatabaseSettings? expected;
    var first = true;
    for (var p in perms) {
      var x = dbs[p[0]], y = dbs[p[1]], z = dbs[p[2]];
      var left = _copyOf(x)
        ..merge(y)
        ..merge(z);
      var right = _copyOf(x)..merge(_copyOf(y)..merge(z));
      expect(left.hasSameContentAs(right), isTrue, reason: 'assoziativ $p');
      expect(left.settings, equals(right.settings), reason: 'assoziativ $p');
      expect(jsonEncode(left.toJson()['settings']),
          equals(jsonEncode(right.toJson()['settings'])));
      if (first) {
        expected = left.settings;
        first = false;
      }
      expect(left.settings, equals(expected), reason: 'kommutativ $p');
      expect(right.settings, equals(expected), reason: 'kommutativ $p');
    }
  }

  test('settings: Merge ist kommutativ und assoziativ (verschiedene Zeiten, '
      'auch null und fehlendes Register)', () {
    expectLattice([
      withSettings('a', gh('t1'), s1),
      withSettings('b', null, s3),
      withSettings('c', gh('t2'), s2),
    ]);
    expectLattice([
      withSettings('a', gh('t1'), s1),
      withSettings('b', gh('t2'), s2),
      withSettings('c', null, null),
    ]);
    expectLattice([
      withSettings('a', null, s2),
      withSettings('b', gh('t2'), s1),
      withSettings('c', null, null),
    ]);
  });

  test('settings: Merge ist kommutativ und assoziativ bei gleicher Zeit '
      '(Tie-Break), auch mit null', () {
    expectLattice([
      withSettings('a', gh('t1'), s1),
      withSettings('b', gh('t2'), s1),
      withSettings('c', null, s1),
    ]);
    expectLattice([
      withSettings('a', gh('t1', repo: 'x'), s1),
      withSettings('b', gh('t1', repo: 'y'), s1),
      withSettings('c', gh('t1', branch: 'dev'), s1),
    ]);
    // Dieselbe Zeit, ausgedrueckt in verschiedenen Zeitzonen-Schreibweisen.
    expectLattice([
      withSettings('a', gh('t1'), s1),
      withSettings('b', gh('t2'), s1.add(Duration.zero)),
      withSettings('c', gh('t3'), DateTime.parse('2024-05-01T12:00:00+02:00')),
    ]);
  });

  test('settings: Merge ist idempotent', () {
    var a = withSettings('a', gh('t1'), s1);
    var b = withSettings('b', gh('t2'), s2);
    var aa = _copyOf(a)..merge(a);
    expect(aa.settings, equals(a.settings));
    expect(aa.hasSameContentAs(a), isTrue);

    var ab = _copyOf(a)..merge(b);
    var again = _copyOf(ab)..merge(b);
    expect(again.settings, equals(ab.settings));
    expect(again.hasSameContentAs(ab), isTrue);
    var selfAgain = _copyOf(ab)..merge(ab);
    expect(selfAgain.hasSameContentAs(ab), isTrue);
  });

  test('settings: null gegen Wert, die neuere Zeit gewinnt in beide '
      'Richtungen', () {
    var value = withSettings('a', gh('t1'), s1);
    var removedLater = withSettings('b', null, s2);
    var removedEarlier = withSettings('c', null, s1.subtract(Duration(days: 1)));

    var r1 = _copyOf(value)..merge(removedLater);
    var r2 = _copyOf(removedLater)..merge(value);
    for (var r in [r1, r2]) {
      expect(r.settings, isNotNull);
      expect(r.settings!.github, isNull);
      expect(r.settings!.time, equals(s2));
    }

    var v1 = _copyOf(value)..merge(removedEarlier);
    var v2 = _copyOf(removedEarlier)..merge(value);
    for (var r in [v1, v2]) {
      expect(r.settings!.github, equals(gh('t1')));
      expect(r.settings!.time, equals(s1));
    }

    // "GitHub entfernt" ueberlebt den Roundtrip als ausdruecklicher Wert.
    var restored = _copyOf(r1);
    expect(restored.settings, isNotNull);
    expect(restored.settings!.github, isNull);
    expect(jsonEncode(restored.toJson()['settings']),
        equals('{"time":"${s2.toIso8601String()}","github":null}'));
  });

  test('settings: fehlendes Register verliert gegen jeden Wert, auch null',
      () {
    var none = withSettings('a', null, null);
    var removed = withSettings('b', null, DateTime.utc(1970));
    expect(none.settings, isNull);
    expect((_copyOf(none)..merge(removed)).settings, equals(removed.settings));
    expect((_copyOf(removed)..merge(none)).settings, equals(removed.settings));
    var bothNone = _copyOf(none)..merge(withSettings('c', null, null));
    expect(bothNone.settings, isNull);
  });

  test('settings: gleiche Zeit, verschiedener Wert -> deterministisch und '
      'richtungsunabhaengig (groesserer kanonischer JSON-String)', () {
    var a = withSettings('a', gh('aaa'), s1);
    var b = withSettings('b', gh('bbb'), s1);
    var n = withSettings('c', null, s1);

    var ab = _copyOf(a)..merge(b);
    var ba = _copyOf(b)..merge(a);
    expect(ab.settings, equals(ba.settings));
    expect(ab.settings!.github, equals(gh('bbb')));

    // Objekt (beginnt mit '{') ist groesser als der JSON-Text 'null'.
    var an = _copyOf(a)..merge(n);
    var na = _copyOf(n)..merge(a);
    expect(an.settings!.github, equals(gh('aaa')));
    expect(na.settings!.github, equals(gh('aaa')));
    expect(an.hasSameContentAs(na), isTrue);
  });

  test('settings: toJson/fromJson-Roundtrip, Zeit in UTC', () {
    var db = withSettings('a', gh(secret, owner: 'ow', repo: 're', branch: 'br'),
        DateTime.parse('2024-05-01T12:00:00+02:00'));
    expect(db.settings!.time.isUtc, isTrue);
    var json = db.toJson();
    expect(json['settings'], equals({
      'time': '2024-05-01T10:00:00.000Z',
      'github': {'token': secret, 'owner': 'ow', 'repo': 're', 'branch': 'br'},
    }));
    var back = _copyOf(db);
    expect(back.settings, equals(db.settings));
    expect(back.settings!.github!.token, equals(secret));
    expect(back.settings!.github!.branch, equals('br'));
    expect(back.settings!.time, equals(DateTime.utc(2024, 5, 1, 10)));
    expect(back.hasSameContentAs(db), isTrue);
  });

  test('settings: fehlendes Feld heisst nichts gesetzt und wird nicht '
      'geschrieben; settings:null wird wie fehlend gelesen', () {
    var db = _singleEntryDb('a', [_v('a', _t1)]);
    expect(db.settings, isNull);
    expect(db.toJson().containsKey('settings'), isFalse);

    var legacy = UltracipherDatabase.fromJson(
        {'entries': [], 'deleted': <dynamic>[]});
    expect(legacy.settings, isNull);
    expect(legacy.toJson().containsKey('settings'), isFalse);

    var explicitNull =
        UltracipherDatabase.fromJson({'entries': [], 'settings': null});
    expect(explicitNull.settings, isNull);
  });

  test('settings: fehlerhafte Felder -> FormatException ohne Token in der '
      'Meldung', () {
    Object? failure(dynamic settings) {
      try {
        UltracipherDatabase.fromJson({'entries': [], 'settings': settings});
      } on FormatException catch (e) {
        return e;
      }
      return null;
    }

    var good = {'token': secret, 'owner': 'o', 'repo': 'r', 'branch': 'b'};
    var time = '2024-05-01T10:00:00.000Z';
    for (var bad in <dynamic>[
      'text',
      {'github': null},
      {'time': 5, 'github': null},
      {'time': 'kein-datum', 'github': null},
      {'time': time},
      {'time': time, 'github': 'x'},
      {'time': time, 'github': {...good, 'branch': 7}},
      {'time': time, 'github': {...good}..remove('branch')},
      {'time': time, 'github': {...good, 'token': 12345}},
    ]) {
      var e = failure(bad);
      expect(e, isA<FormatException>(), reason: '$bad');
      expect(e.toString(), isNot(contains(secret)));
    }
    expect(failure({'time': time, 'github': good}), isNull);
  });

  test('settings: hasSameContentAs erkennt Unterschiede in Zeit, Wert, null '
      'und fehlendem Register', () {
    var base = withSettings('x', gh('t1'), s1);
    expect(base.hasSameContentAs(_copyOf(base)), isTrue);

    expect(base.hasSameContentAs(withSettings('x', gh('t1'), null)), isFalse);
    expect(withSettings('x', gh('t1'), null).hasSameContentAs(base), isFalse);
    expect(base.hasSameContentAs(withSettings('x', gh('t1'), s2)), isFalse);
    expect(base.hasSameContentAs(withSettings('x', gh('t2'), s1)), isFalse);
    expect(base.hasSameContentAs(withSettings('x', gh('t1', owner: 'p'), s1)),
        isFalse);
    expect(base.hasSameContentAs(withSettings('x', gh('t1', repo: 'p'), s1)),
        isFalse);
    expect(
        base.hasSameContentAs(withSettings('x', gh('t1', branch: 'p'), s1)),
        isFalse);
    expect(base.hasSameContentAs(withSettings('x', null, s1)), isFalse);
    expect(withSettings('x', null, s1).hasSameContentAs(withSettings('x', null, s1)),
        isTrue);
    expect(withSettings('x', null, s1).hasSameContentAs(withSettings('x', null, s2)),
        isFalse);
    // Gleicher Zeitpunkt in anderer Schreibweise ist gleich.
    expect(
        base.hasSameContentAs(withSettings(
            'x', gh('t1'), DateTime.parse('2024-05-01T12:00:00+02:00'))),
        isTrue);
  });

  test('settings: Merge teilt keine Objekte', () {
    var a = withSettings('a', gh('t1'), s2);
    var b = withSettings('b', gh('t2'), s1);

    var target = UltracipherDatabase();
    target.merge(a);
    expect(target.settings, equals(a.settings));
    expect(identical(target.settings, a.settings), isFalse);
    expect(identical(target.settings!.github, a.settings!.github), isFalse);

    // Gewinnt die eigene Seite, bleibt other unberuehrt und ungeteilt.
    var mine = _copyOf(a)..merge(b);
    expect(mine.settings, equals(a.settings));
    expect(identical(mine.settings!.github, b.settings!.github), isFalse);
    expect(b.settings!.github, equals(gh('t2')));
    expect(b.settings!.time, equals(s1));

    // Spaetere Aenderung von other wirkt nicht auf das Ergebnis.
    var c = withSettings('c', gh('t3'), s3);
    var merged = UltracipherDatabase()..merge(c);
    c.setSettings(github: null, time: DateTime.utc(2030));
    expect(merged.settings!.github, equals(gh('t3')));
  });

  test('settings: Merge veraendert other nicht, Self-Merge ist harmlos', () {
    var a = withSettings('a', gh('t1'), s1);
    var b = withSettings('b', gh('t2'), s2);
    var before = jsonEncode(b.toJson());
    a.merge(b);
    expect(jsonEncode(b.toJson()), equals(before));
    var selfBefore = jsonEncode(a.toJson());
    a.merge(a);
    expect(jsonEncode(a.toJson()), equals(selfBefore));
  });

  test('settings: nicht im CSV-Export', () {
    var db = withSettings('a', gh(secret, owner: 'ownerXYZ', repo: 'repoXYZ'),
        s1);
    var csv = db.toCSV();
    expect(csv, isNot(contains(secret)));
    expect(csv, isNot(contains('ownerXYZ')));
    expect(csv, isNot(contains('repoXYZ')));
    expect(csv, isNot(contains('settings')));
    expect(csv, equals(withSettings('a', null, null).toCSV()));
  });

  test('settings: toString enthaelt das Token nie', () {
    var github = gh(secret, owner: 'ownerXYZ');
    expect(github.toString(), isNot(contains(secret)));
    expect(github.toString(), contains('ownerXYZ'));
    var settings = DatabaseSettings(time: s1, github: github);
    expect(settings.toString(), isNot(contains(secret)));
    expect(settings.toString(), contains('ownerXYZ'));
    expect(DatabaseSettings(time: s1).toString(), contains('none'));
  });

  test('settings: Merge in eine Datenbank veraendert Eintraege und Loeschliste '
      'nicht', () {
    var a = _singleEntryDb('x', [_v('x', _t1)]);
    var b = withSettings('y', gh('t1'), s1);
    var signature = _signature(a);
    a.merge(_singleEntryDb('x', [_v('x', _t1)])
      ..setSettings(github: gh('t9'), time: s3));
    expect(_signature(a), equals(signature));
    expect(a.settings!.github, equals(gh('t9')));
    expect(a.deletions, isEmpty);
    expect(b.settings, isNotNull);
  });
}
