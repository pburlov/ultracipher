import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/core.dart';

import 'fake_remote_backend.dart';
import 'memoized_key_derivation.dart';

const _header5 = 'id,create date,name,tags,body';
const _header4 = 'create date,name,tags,body';

// Ausgabe des echten Alt-Exporters: `UltracipherDatabase.toCSV` aus
// ultracipher-core (zuletzt in 6979789^), das nur die Angular-Webapp aufrief:
// `ListToCsvConverter().convert([label, tags, content] je Eintrag)` aus csv
// 5.1.1 (die App band ^5.0.2). Keine Kopfzeile, Trenner `,`, Zeilenende `\r\n`
// ohne abschliessendes, Anfuehrungszeichen wo ein Feld `,`, `"`, `\r` oder `\n`
// enthaelt; tags ist ein einfacher Text. Erzeugt aus
// ['Bank, main','finance bank','user: me\nPIN "1234"'], ['Mail','','secret'],
// ['007','1e5','12345678901234567890'] (csv 8.0.0 liefert dasselbe). Nicht neu
// erzeugen.
const _oldThreeColumn =
    '"Bank, main",finance bank,"user: me\nPIN ""1234"""\r\nMail,,secret\r\n'
    '007,1e5,12345678901234567890';

/// Reads through to [inner], but every write fails (a full disk).
class _UnwritableStorage implements SharedPreferences {
  final SharedPreferences inner;

  _UnwritableStorage(this.inner);

  @override
  String? getString(String key) => inner.getString(key);

  @override
  Future<bool> setString(String key, String value) =>
      Future.error(StateError('disk full'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stand der Datenbank als JSON-Text, zum Vergleichen vorher/nachher.
String _state(UltracipherDatabase db) => jsonEncode(db.toJson());

UltracipherDatabase _db(Map<String, String> bodiesById) {
  var db = UltracipherDatabase();
  bodiesById.forEach((id, body) {
    db.addEntry(entry: VersionedEntry(id)).addNewVersion(Entry(
        label: 'L$id',
        tags: 't',
        content: body,
        createTime: '2020-01-01T00:00:00.000Z'));
  });
  return db;
}

/// Zeilen (label, tags, content) der neuesten Versionen, sortiert.
List<List<String>> _rows(UltracipherDatabase db) {
  var rows = [
    for (var e in db.allEntries)
      [e.latestEntry!.label, e.latestEntry!.tags, e.latestEntry!.content]
  ];
  rows.sort((a, b) => a.join('\u0000').compareTo(b.join('\u0000')));
  return rows;
}

void main() {
  useMemoizedKeyDerivation();
  group('export', () {
    test('writes the header with id first, one row per entry', () {
      var db = _db({'a': 'x'});
      var lines = LineSplitter.split(db.toCSV()).toList();
      expect(lines, [_header5, 'a,2020-01-01T00:00:00.000Z,La,t,x']);
    });

    test('never contains the settings', () {
      var db = _db({'a': 'x'});
      db.setSettings(
          github: GithubSettings(
              token: 'tok-SECRET', owner: 'own', repo: 'rep', branch: 'main'));
      var csv = db.toCSV();
      expect(csv, isNot(contains('SECRET')));
      expect(csv, isNot(contains('own')));
    });

    test('keeps the insertion order, also for many entries', () {
      var db = UltracipherDatabase();
      for (var i = 0; i < 100; i++) {
        db.addEntry(entry: VersionedEntry('id$i')).addNewVersion(Entry(
            label: 'n$i', createTime: '2020-01-01T00:00:00.000Z'));
      }
      var ids = [
        for (var line in LineSplitter.split(db.toCSV()).skip(1))
          line.split(',').first
      ];
      expect(ids, [for (var i = 0; i < 100; i++) 'id$i']);
    });
  });

  group('known id', () {
    test('same content: nothing happens', () {
      var db = _db({'a': 'x'});
      var before = _state(db);
      var result = importCsvInto(db,
          '$_header5\na,2001-01-01T00:00:00.000Z,La,t,x\n');
      expect(result.count, 0);
      expect(_state(db), before);
    });

    test('different content: new newest version at now (UTC), CSV date ignored',
        () {
      var db = _db({'a': 'x'});
      var start = DateTime.now().toUtc();
      var result = importCsvInto(db,
          '$_header5\na,2001-01-01T00:00:00.000Z,La,t,changed\n');
      var end = DateTime.now().toUtc();
      expect(result.count, 1);
      var entry = db.getEntryWhitId('a')!;
      expect(entry.versions.length, 2);
      expect(entry.latestEntry!.content, 'changed');
      expect(entry.latestEntry!.createTime.endsWith('Z'), isTrue);
      var time = entry.latestEntry!.createDateTime;
      expect(time.isBefore(start), isFalse);
      expect(time.isAfter(end), isFalse);
      // Die alte Version bleibt.
      expect(entry.versions.last.content, 'x');
      expect(db.allEntries.length, 1);
    });

    test('ids are compared as strings (int id in the database)', () {
      var db = UltracipherDatabase();
      db.addEntry(entry: VersionedEntry(7)).addNewVersion(Entry(
          label: 'n', createTime: '2020-01-01T00:00:00.000Z'));
      importCsvInto(db, '$_header5\n7,,n,,more\n');
      expect(db.allEntries.length, 1);
      expect(db.allEntries.single.versions.length, 2);
      // '007' ist nicht dieselbe id wie 7.
      importCsvInto(db, '$_header5\n007,,n,,more\n');
      expect(db.allEntries.length, 2);
    });

    test('newest version in the future: the new version still becomes newest',
        () {
      var db = UltracipherDatabase();
      var future = DateTime.now().toUtc().add(Duration(days: 1));
      db.addEntry(entry: VersionedEntry('a')).addNewVersion(
          Entry(label: 'n', createTime: future.toIso8601String()));
      importCsvInto(db, '$_header5\na,,n,,other\n');
      expect(db.getEntryWhitId('a')!.latestEntry!.content, 'other');
    });
  });

  group('unknown id', () {
    test('new entry with this id and the CSV date', () {
      var db = _db({'a': 'x'});
      var result = importCsvInto(
          db, '$_header5\nnew,2001-02-03T04:05:06.000Z,N,tg,body\n');
      expect(result.count, 1);
      var entry = db.getEntryWhitId('new')!;
      expect(entry.latestEntry!.createTime, '2001-02-03T04:05:06.000Z');
      expect(entry.latestEntry!.label, 'N');
      expect(db.allEntries.length, 2);
    });

    test('empty date cell means now', () {
      var db = UltracipherDatabase();
      importCsvInto(db, '$_header5\nnew,,N,,b\n');
      expect(db.getEntryWhitId('new')!.latestEntry!.createTime.endsWith('Z'),
          isTrue);
    });

    test('id in the deletion list: createTime is now, the entry survives', () {
      var db = _db({'a': 'x'});
      var gone = db.addEntry(entry: VersionedEntry('gone'))
        ..addNewVersion(Entry(
            label: 'old', createTime: '2020-01-01T00:00:00.000Z'));
      db.deleteEntry(gone, deletedAt: DateTime.utc(2024, 1, 1));
      var start = DateTime.now().toUtc();
      var result = importCsvInto(
          db, '$_header5\ngone,2001-01-01T00:00:00.000Z,back,,b\n');
      expect(result.count, 1);
      var entry = db.getEntryWhitId('gone')!;
      expect(entry.latestEntry!.createDateTime.isBefore(start), isFalse);
      // Ein Merge mit der Loeschliste (und das Neuladen) verwirft ihn nicht.
      db.merge(UltracipherDatabase());
      var reloaded = UltracipherDatabase.fromJson(
          jsonDecode(jsonEncode(db.toJson())) as Map<String, dynamic>);
      expect(db.getEntryWhitId('gone'), isNotNull);
      expect(reloaded.getEntryWhitId('gone')!.latestEntry!.label, 'back');
    });

    test('deletion in the future: still imported', () {
      var db = UltracipherDatabase();
      var gone = db.addEntry(entry: VersionedEntry('gone'))
        ..addNewVersion(Entry(label: 'old'));
      db.deleteEntry(gone,
          deletedAt: DateTime.now().toUtc().add(Duration(days: 2)));
      importCsvInto(db, '$_header5\ngone,,back,,b\n');
      expect(db.getEntryWhitId('gone')!.latestEntry!.label, 'back');
      // Auch nach Merge und Neuladen (dort greift die Loeschliste) bleibt er.
      db.merge(UltracipherDatabase());
      var reloaded = UltracipherDatabase.fromJson(
          jsonDecode(jsonEncode(db.toJson())) as Map<String, dynamic>);
      reloaded.merge(db);
      expect(reloaded.getEntryWhitId('gone')!.latestEntry!.label, 'back');
    });
  });

  group('blank rows', () {
    test('unknown id with an empty name, tags and body creates nothing', () {
      var db = _db({'a': 'x'});
      var deletions = db.deletions;
      var result = importCsvInto(db, '$_header5\nx,2001-01-01T00:00:00.000Z,,,\n');
      expect(result.count, 0);
      expect(db.allEntries.length, 1);
      expect(db.getEntryWhitId('x'), isNull);
      db.cleanUp();
      expect(db.allEntries.length, 1);
      expect(db.deletions, deletions);
    });

    test('empty id and the old formats: blank rows are skipped too', () {
      for (var csv in [
        '$_header5\n,,,,\n,2001-01-01T00:00:00.000Z,,,\n',
        '$_header4\n2001-01-01T00:00:00.000Z,,,\n',
        ',,\n',
      ]) {
        var db = _db({'a': 'x'});
        // Eine Zeile mit Inhalt dabei, damit das Format erkannt wird.
        var content = csv.startsWith(',,\n') ? 'n,t,b\n$csv' : csv;
        var result = importCsvInto(db, content);
        expect(result.count, content.startsWith('n,t,b') ? 1 : 0, reason: csv);
        db.cleanUp();
        expect(db.deletions, isEmpty, reason: csv);
      }
    });

    test('a known id may still change to blank content', () {
      var db = _db({'a': 'x'});
      var result = importCsvInto(db, '$_header5\na,,La,t,\n');
      expect(result.count, 1);
      expect(db.getEntryWhitId('a')!.versions.length, 2);
    });
  });

  group('int ids of old databases', () {
    test('a canonical integer id is created as int and merges without a '
        'duplicate', () {
      var db = UltracipherDatabase();
      db.addEntry(entry: VersionedEntry(5)).addNewVersion(Entry(
          label: 'n', createTime: '2020-01-01T00:00:00.000Z'));
      var csv = db.toCSV();
      var copy = UltracipherDatabase();
      importCsvInto(copy, csv);
      expect(copy.allEntries.single.id, 5);
      expect(copy.toCSV(), csv);
      copy.merge(db);
      expect(copy.allEntries.length, 1);
      expect(importCsvInto(copy, copy.toCSV()).count, 0);
    });

    test('other id strings stay strings', () {
      var db = UltracipherDatabase();
      importCsvInto(
          db,
          '$_header5\n007,,a,,b\n+5,,a,,b\n-0,,a,,b\n1e5,,a,,b\n'
          '5.0,,a,,b\n12345678901234567890,,a,,b\n-3,,a,,b\n0,,a,,b\n');
      expect(db.getEntryWhitId('007')!.id, isA<String>());
      for (var id in ['+5', '-0', '1e5', '5.0', '12345678901234567890']) {
        expect(db.allEntries.firstWhere((e) => e.id.toString() == id).id,
            isA<String>(),
            reason: id);
      }
      expect(db.allEntries.firstWhere((e) => e.id.toString() == '-3').id, -3);
      expect(db.allEntries.firstWhere((e) => e.id.toString() == '0').id, 0);
    });
  });

  group('empty id and old formats (no id)', () {
    test('empty id: new entry with a fresh id', () {
      var db = _db({'a': 'x'});
      var result = importCsvInto(db, '$_header5\n,,Fresh,,body\n');
      expect(result.count, 1);
      expect(db.allEntries.length, 2);
      var ids = db.allEntries.map((e) => e.id.toString()).toSet();
      expect(ids.length, 2);
      expect(ids.contains(''), isFalse);
    });

    test('empty id with the same text as an existing entry is skipped', () {
      var db = _db({'a': 'x'});
      var before = _state(db);
      var result = importCsvInto(db, '$_header5\n,,La,t,x\n');
      expect(result.count, 0);
      expect(_state(db), before);
    });

    test('empty id, same text as only an OLDER version: new entry', () {
      var db = _db({'a': 'x'});
      importCsvInto(db, '$_header5\na,,La,t,y\n');
      var result = importCsvInto(db, '$_header5\n,,La,t,x\n');
      expect(result.count, 1);
      expect(db.allEntries.length, 2);
    });

    test('4 columns with header: rows without id, CSV date is used', () {
      var db = _db({'a': 'x'});
      var result = importCsvInto(db,
          '$_header4\n2001-02-03T04:05:06.000Z,Old,tg,"line1\nline2"\n');
      expect(result.count, 1);
      var e = db.allEntries.firstWhere((e) => e.id != 'a');
      expect(e.latestEntry!.createTime, '2001-02-03T04:05:06.000Z');
      expect(e.latestEntry!.content, 'line1\nline2');
    });

    test('4 columns: header detection trims and ignores case', () {
      var db = UltracipherDatabase();
      var result = importCsvInto(
          db, ' Create Date ,name,tags,body\n2001-02-03T04:05:06.000Z,a,b,c\n');
      expect(result.count, 1);
    });

    test('3 columns without header (real old exporter output)', () {
      var db = _db({'a': 'x'});
      var start = DateTime.now().toUtc();
      var result = importCsvInto(db, _oldThreeColumn);
      expect(result.count, 3);
      expect(db.allEntries.length, 4);
      expect(_rows(db), [
        ['007', '1e5', '12345678901234567890'],
        ['Bank, main', 'finance bank', 'user: me\nPIN "1234"'],
        ['La', 't', 'x'],
        ['Mail', '', 'secret'],
      ]);
      for (var e in db.allEntries.where((e) => e.id != 'a')) {
        var t = e.latestEntry!.createDateTime;
        expect(t.isBefore(start), isFalse);
        expect(e.latestEntry!.createTime.endsWith('Z'), isTrue);
      }
    });

    test('importing the same old CSV again creates no duplicates', () {
      for (var csv in [
        _oldThreeColumn,
        '$_header4\n2001-02-03T04:05:06.000Z,Old,tg,body\n'
            '2002-02-03T04:05:06.000Z,Old2,,b2\n',
      ]) {
        var db = UltracipherDatabase();
        expect(importCsvInto(db, csv).count, greaterThan(0));
        var before = _state(db);
        expect(importCsvInto(db, csv).count, 0);
        expect(_state(db), before);
      }
    });

    test('a BOM in front of the header is ignored', () {
      var db = UltracipherDatabase();
      var r5 = importCsvInto(db, '﻿$_header5\nn,,N,,b\n');
      var r4 = importCsvInto(
          db, '﻿$_header4\n2001-02-03T04:05:06.000Z,O,,b\n');
      expect(r5.count, 1);
      expect(r4.count, 1);
      expect(db.allEntries.length, 2);
    });

    test('empty file and header only import nothing', () {
      var db = _db({'a': 'x'});
      var before = _state(db);
      expect(importCsvInto(db, '').count, 0);
      expect(importCsvInto(db, '$_header5\n').count, 0);
      expect(importCsvInto(db, _header4).count, 0);
      expect(_state(db), before);
    });
  });

  group('invalid files leave the database unchanged', () {
    var good = 'a,,La,t,changed\nnew,,N,,b\n';
    var bad = <String, String>{
      '4 columns without header': 'x,y,z,w\n',
      '5 columns without header': 'x,y,z,w,v\n',
      '2 columns': 'x,y\n',
      '1 column': 'x\n',
      'header with wrong names': 'id,create date,name,body,tags\n$good',
      'header with wrong width': 'id,create date,name,tags\n$good',
      'short row': '$_header5\n$good'
          'short,row,only\n',
      'long row': '$_header5\n${good}a,b,c,d,e,f\n',
      '3 columns, then a different width': 'n,t,b\nn,t\n',
      'unreadable date': '$_header5\n${good}z,not a date,N,,b\n',
      'duplicate id': '$_header5\n${good}dup,,N,,b\ndup,,M,,c\n',
      'duplicate id, known': '$_header5\na,,La,t,x1\na,,La,t,x2\n',
      'old header, wrong width': '$_header4\n2001-01-01,a,b\n',
    };
    bad.forEach((name, csv) {
      test(name, () {
        var db = _db({'a': 'x'});
        var before = _state(db);
        expect(() => importCsvInto(db, csv), throwsFormatException);
        expect(_state(db), before);
      });
    });

    test('the model and core errors never contain cell contents', () {
      const secret = 'TOPSECRET';
      var cases = [
        '$_header5\na,,La,t,x\n$secret,$secret\n',
        '$_header5\n$secret,not-$secret,N,,b\n',
        '$_header5\n$secret,,N,,b\n$secret,,N,,c\n',
        '$secret,$secret,$secret,$secret\n',
        '$secret,$secret\n',
        '$_header4\n$secret,$secret,$secret,$secret\n',
        'id,$secret,name,tags,body\n',
        '$_header4\n$secret,x,y\n',
      ];
      for (var csv in cases) {
        Object? coreError;
        try {
          importCsvInto(_db({'a': 'x'}), csv);
        } catch (e) {
          coreError = e;
        }
        expect(coreError, isA<FormatException>(), reason: csv);
        expect(coreError.toString(), isNot(contains(secret)), reason: csv);
        expect((coreError as FormatException).source, isNull);
        Object? modelError;
        try {
          _db({'a': 'x'}).importFromCsv(csv);
        } catch (e) {
          modelError = e;
        }
        expect(modelError.toString(), isNot(contains(secret)), reason: csv);
        expect((modelError as FormatException).source, isNull);
      }
    });

    test('the error names the line', () {
      expect(
          () => importCsvInto(UltracipherDatabase(), '$_header5\na,,b,c,d\nx,y\n'),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('CSV record 3: 2 columns instead of 5'))));
    });
  });

  test('nothing is ever deleted: absent entries and deletions stay', () {
    var db = _db({'a': 'x', 'b': 'y'});
    var gone = db.addEntry(entry: VersionedEntry('c'))
      ..addNewVersion(Entry(label: 'c'));
    db.deleteEntry(gone, deletedAt: DateTime.utc(2024, 1, 1));
    var deletions = db.deletions;
    importCsvInto(
        db, '$_header5\nz,,Z,,z\nb,,Lb,t,changed\n,,Fresh,,f\n,,La,t,x\n');
    expect(db.getEntryWhitId('a')!.latestEntry!.content, 'x');
    expect(db.getEntryWhitId('b')!.versions.length, 2);
    expect(db.allEntries.length, 4);
    expect(db.deletions, deletions);
  });

  test('undo takes back exactly what the import did', () {
    var db = _db({'a': 'x'});
    var before = _state(db);
    var result = importCsvInto(db, '$_header5\na,,La,t,c\nn,,N,,b\n,,M,,b\n');
    expect(result.count, 3);
    expect(_state(db), isNot(before));
    result.undo();
    expect(_state(db), before);
  });

  group('roundtrip', () {
    // Ids und Felder, die wie Zahlen aussehen, dazu Sonderzeichen und Zeiten
    // ohne Z (lokal, aus alten Eintraegen).
    UltracipherDatabase tricky() {
      var db = UltracipherDatabase();
      var i = 0;
      void add(dynamic id, String label, String tags, String content,
          String time) {
        db.addEntry(entry: VersionedEntry(id)).addNewVersion(Entry(
            label: label, tags: tags, content: content, createTime: time));
        i++;
      }

      add('007', '007', '1e5', '12345678901234567890', '2020-01-01T00:00:00.000Z');
      add('1e5', '0x1F', 'true', 'null', '2021-05-04T03:02:01.123456Z');
      add('12345678901234567890', '-0', '1.0', '  ', '2020-05-04T03:02:01.000');
      add(7, '.5', 'NaN', 'Infinity', '2019-12-31T23:59:59.999Z');
      add('plain-id', 'Bank, "main"', 'a b  c', 'line1\r\nline2\nline3\rx',
          '2020-01-01T00:00:00.000+02:00');
      add(' pad ', 'pad', '', 'x', '2020-01-01T00:00:00.000Z');
      add('quote', '"', '""', '"a"', '2020-01-01T00:00:00.000Z');
      add('uml', 'Müller 日本語 😀', '', 'x', '2020-01-01T00:00:00.000Z');
      expect(i, 8);
      // Mehr als 32 Eintraege: List.sort waere dort nicht mehr stabil.
      for (var n = 0; n < 100; n++) {
        add('id$n', 'n$n', '', '$n', '2020-01-01T00:00:00.000Z');
      }
      return db;
    }

    test('export -> import into the same database changes nothing', () {
      var db = tricky();
      var before = _state(db);
      var result = importCsvInto(db, db.toCSV());
      expect(result.count, 0);
      expect(_state(db), before);
    });

    test('export -> import into an empty database -> export is byte-identical',
        () {
      var db = tricky();
      var csv = db.toCSV();
      var copy = UltracipherDatabase();
      var result = importCsvInto(copy, csv);
      expect(result.count, db.allEntries.length);
      expect(copy.toCSV(), csv);
      // Auch inhaltlich gleich, ids als Text.
      expect(copy.getEntryWhitId('007')!.latestEntry!.label, '007');
      expect(copy.getEntryWhitId('12345678901234567890'), isNotNull);
      expect(copy.getEntryWhitId(7), isNotNull);
    });

    test('the timestamps do not drift', () {
      var db = tricky();
      var copy = UltracipherDatabase();
      importCsvInto(copy, db.toCSV());
      for (var e in db.allEntries) {
        var c = copy.allEntries.firstWhere((x) => x.id.toString() == e.id.toString());
        expect(c.latestEntry!.createTime, e.latestEntry!.createTime);
      }
    });
  });

  group('importCsvText (app)', () {
    Future<UltracipherApp> open() async {
      SharedPreferences.setMockInitialValues({});
      var app = UltracipherApp();
      await app.init();
      var remote = FakeRemoteBackend();
      var key = await app.deriveRoot('pass');
      await app.createDatabase('pass');
      app.remoteBackend = remote;
      remote.seed(UltracipherApp.encryptDatabase(_db({'a': 'x'}), key));
      await app.syncNow();
      return app;
    }

    test('merges, saves and returns new + changed entries', () async {
      var app = await open();
      var count = await app.importCsvText(
          '$_header5\na,,La,t,x\nb,,Lb,,y\n,,Lc,,z\n');
      expect(count, 2);
      var db = app.loadedDatabase.value!;
      expect(db.allEntries.length, 3);
      var remote = app.remoteBackend as FakeRemoteBackend;
      await app.syncNow();
      var key = await app.deriveRoot('pass');
      expect(
          UltracipherApp.decryptDatabase(remote.storedBytes!, key)
              .allEntries
              .length,
          3);
    });

    test('a failing local save takes the import back', () async {
      var app = await open();
      // The local cache cannot be written (disk full): saveDatabase fails.
      app.storage = _UnwritableStorage(app.storage!);
      var db = app.loadedDatabase.value!;
      var before = _state(db);
      await expectLater(app.importCsvText('$_header5\nb,,Lb,,y\na,,La,t,c\n'),
          throwsA(isA<StateError>()));
      expect(_state(db), before);
    });

    test('an invalid file leaves the database unchanged', () async {
      var app = await open();
      var db = app.loadedDatabase.value!;
      var before = _state(db);
      await expectLater(app.importCsvText('$_header5\nb,,Lb\n'),
          throwsFormatException);
      expect(_state(db), before);
    });
  });
}
