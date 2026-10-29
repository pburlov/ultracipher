import 'dart:convert';

import 'package:test/test.dart' as t;
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:test/test.dart';

void main() {
  late UltracipherDatabase db;
  late String deletedId1;
  late String deletedId2;
  setUp(() {
    db = UltracipherDatabase();
    db.addEntry(); //Empty
    db.addEntry().addNewVersion(Entry(label: ''));
    db.addEntry().addNewVersion(
        Entry(label: 'label1', tags: 'tag1 tag2 "', content: 'con ten t'));
    db.addEntry().addNewVersion(
        Entry(label: 'label2', tags: 'tag1 tag3', content: 'more con ten t'));
    deletedId1 = 'deleted-1';
    deletedId2 = 'deleted-2';
    var deleted1 = db.addEntry(entry: VersionedEntry(deletedId1))
      ..addNewVersion(Entry(label: 'deleted', tags: '', content: ''));
    db.deleteEntry(deleted1,
        deletedAt: DateTime.now().subtract(Duration(days: 60)));
    var deleted2 = db.addEntry(entry: VersionedEntry(deletedId2))
      ..addNewVersion(Entry(label: 'deleted2', tags: '', content: ''));
    db.deleteEntry(deleted2,
        deletedAt: DateTime.now().subtract(Duration(days: 30)));
  });

  test('Add entry', () {
    var freshDb = UltracipherDatabase();
    var entry = freshDb.addEntry();
    var version = Entry();
    version.label = 'label';
    version.tags = 'tags';
    version.content = 'content';
    entry.addNewVersion(version);
    var addedVersion = freshDb.getEntries().first.versions.first;
    expect(addedVersion.label, version.label);
    expect(addedVersion.tags, version.tags);
    expect(addedVersion.content, version.content);
    expect(addedVersion.createTime, version.createTime);
  });

  test('Entry obfuscating', () {
    var createTime = DateTime.now();
    var entry = Entry(
        label: "label text",
        tags: 'tag1',
        content: 'content text',
        createTime: createTime.toIso8601String());
    expect(entry.label, 'label text');
    expect(entry.tags, 'tag1');
    expect(entry.content, 'content text');
    expect(entry.createDateTime.compareTo(createTime), 0);
  });

  test('Neue Zeitstempel sind UTC (Suffix Z) und liegen im Zeitfenster', () {
    // ms-Genauigkeit wie toIso8601String: vorne und hinten 1 ms Toleranz.
    var before = DateTime.now().toUtc().subtract(Duration(milliseconds: 1));
    var entry = Entry();
    var after = DateTime.now().toUtc().add(Duration(milliseconds: 1));
    expect(entry.createTime.endsWith('Z'), isTrue);
    expect(DateTime.parse(entry.createTime).isUtc, isTrue);
    expect(entry.createDateTime.isBefore(before), isFalse);
    expect(entry.createDateTime.isAfter(after), isFalse);
  });

  test('JSON serializing', () {
    var json = db.toJson();
    var jsonString = jsonEncode(json);
    var jsonDecoded = jsonDecode(jsonString);
    var restored = UltracipherDatabase.fromJson(jsonDecoded);
    expect(restored.allEntries.length, 4);
    expect(restored.deletions.length, 2);
    expect(restored.hasSameContentAs(db), true);
    expect(jsonEncode(restored.toJson()), jsonString);
  });
  test('UltracipherDatabase.merge', () {
    var a = UltracipherDatabase();
    var ae = VersionedEntry('1');
    ae.addNewVersion(Entry(
        label: 'l0',
        tags: 't0',
        content: 'c0',
        createTime: DateTime(1, 1, 1, 1).toIso8601String()));
    ae.addNewVersion(Entry(
        label: 'l1',
        tags: 't1',
        content: 'c1',
        createTime: DateTime(1, 1, 1, 2).toIso8601String()));
    ae.addNewVersion(Entry(
        label: 'l2',
        tags: 't2',
        content: 'c2',
        createTime: DateTime(1, 1, 1, 1, 1).toIso8601String()));
    a.addEntry(entry: ae);

    var b = UltracipherDatabase();
    var be = VersionedEntry('1');
    be.addNewVersion(Entry(
        label: 'l0',
        tags: 't0',
        content: 'c0',
        createTime: DateTime(1, 1, 1, 1).toIso8601String()));
    be.addNewVersion(Entry(
        label: 'l1',
        tags: 't1',
        content: 'c1',
        createTime: DateTime(1, 1, 1, 2).toIso8601String()));
    be.addNewVersion(Entry(
        label: 'l2',
        tags: 't2',
        content: 'c2',
        createTime: DateTime(1, 1, 1, 1, 1).toIso8601String()));
    be.addNewVersion(Entry(
        label: 'l3',
        tags: 't3',
        content: 'c3',
        createTime: DateTime(1, 1, 1, 2, 1).toIso8601String()));
    b.addEntry(entry: be);

    var ce = b.addEntry();
    ce.addNewVersion(Entry(label: 'l4', tags: 't4', content: 'c4'));

    a.merge(b);

    expect(a.allEntries.length, t.equals(2));
    expect(a.getEntryWhitId('1')!.versions.length, t.equals(4));
    expect(a.getEntryWhitId('1')!.latestChangeTime,
        t.equals(DateTime(1, 1, 1, 2, 1)));
  });

  test('VersionedEntry.merge', () {
    var a = VersionedEntry('1');
    a.addNewVersion(Entry(
        label: 'l0',
        tags: 't0',
        content: 'c0',
        createTime: DateTime(1, 1, 1, 1).toIso8601String()));
    a.addNewVersion(Entry(
        label: 'l1',
        tags: 't1',
        content: 'c1',
        createTime: DateTime(1, 1, 1, 2).toIso8601String()));

    var b = VersionedEntry('1');
    b.addNewVersion(Entry(
        label: 'l2',
        tags: 't2',
        content: 'c2',
        createTime: DateTime(1, 1, 1, 1, 1).toIso8601String()));
    b.addNewVersion(Entry(
        label: 'l3',
        tags: 't3',
        content: 'c3',
        createTime: DateTime(1, 1, 1, 2, 1).toIso8601String()));

    a.merge(b);

    expect(a.versions.length, t.equals(4));
    expect(a.latestChangeTime, t.equals(DateTime(1, 1, 1, 2, 1)));
  });
  test('UltracipherDatabase.cleanUp', () {
    // 4 lebendige Eintraege (2 davon leer); 60 und 30 Tage alte Loeschungen.
    expect(db.allEntries.length, t.equals(4));
    expect(db.deletions.keys, t.unorderedEquals([deletedId1, deletedId2]));

    // Die leeren Eintraege verschwinden und landen in der Loeschliste.
    db.cleanUp(deleteOlderThat: Duration(days: 61));
    expect(db.allEntries.length, t.equals(2));
    expect(db.deletions.length, t.equals(4));

    db.cleanUp(deleteOlderThat: Duration(days: 31));
    expect(db.deletions.length, t.equals(3));
    expect(db.deletions.keys, t.isNot(t.contains(deletedId1)));
    expect(db.deletions.keys, t.contains(deletedId2));

    db.cleanUp(deleteOlderThat: Duration(days: 10));
    expect(db.deletions.length, t.equals(2));
    expect(db.deletions.keys, t.isNot(t.contains(deletedId2)));
    expect(db.allEntries.length, t.equals(2));
  });
  test('VersionedEntry.isEmpty', () {
    var ve = VersionedEntry(0);
    expect(true, t.equals(ve.isEmpty));
    ve = VersionedEntry(0);
    ve.addNewVersion(Entry(tags: ''));
    expect(true, t.equals(ve.isEmpty));
    ve.addNewVersion(Entry(tags: 't'));
    expect(false, t.equals(ve.isEmpty));
  });

  test('Entry.isEmpty', () {
    var entry = Entry(label: 'l', tags: '', content: '');
    expect(entry.isEmpty, t.equals(false));
    entry = Entry(label: '', tags: 't', content: '');
    expect(entry.isEmpty, t.equals(false));
    entry = Entry(label: '', tags: '', content: 'c');
    expect(entry.isEmpty, t.equals(false));
    entry = Entry(label: '', tags: '', content: '');
    expect(entry.isEmpty, t.equals(true));
  });
  test('CSV save/load', () {
    var csv = 'create date,name,tags,body\n'
        '2024-01-01T10:00:00.000,labeL1,"tag1 tag2 """,'
        '"con ten t"\n2024-01-02T10:00:00.000,label2,tag1 tag3,"more con ten t"\n';
    var loadedDb = UltracipherDatabase();
    var imported = loadedDb.importFromCsv(csv);
    expect(imported.count, 2);
    expect(imported.added.length, 2);
    var first = loadedDb.allEntries
        .firstWhere((e) => e.latestEntry!.label == 'labeL1');
    expect(first.latestEntry!.tags, 'tag1 tag2 "');
    expect(first.latestEntry!.content, 'con ten t');
    expect(first.latestEntry!.createTime, '2024-01-01T10:00:00.000');
    expect(loadedDb.getEntries().length, 2);
  });

  group('CSV id, create date, name, tags, body', () {
    test('Roundtrip toCSV -> importFromCsv keeps id, values and createTime', () {
      var createTime = DateTime(2020, 5, 4, 3, 2, 1).toIso8601String();
      var src = UltracipherDatabase();
      var a = src.addEntry()
        ..addNewVersion(Entry(
            label: 'a, "b"',
            tags: 'x y',
            content: 'Zeile1,\n"Zeile2"\nZeile3',
            createTime: createTime));
      src.addEntry().addNewVersion(Entry(
          label: 'nur-label',
          tags: '',
          content: '',
          createTime: DateTime(2021, 1, 1).toIso8601String()));

      var csv = src.toCSV();
      var dst = UltracipherDatabase();
      var imported = dst.importFromCsv(csv);

      expect(imported.count, 2);
      var first = dst.getEntryWhitId(a.id)!;
      expect(first.latestEntry!.label, 'a, "b"');
      expect(first.latestEntry!.tags, 'x y');
      expect(first.latestEntry!.content, 'Zeile1,\n"Zeile2"\nZeile3');
      expect(first.latestEntry!.createTime, createTime);
      var second =
          dst.allEntries.firstWhere((e) => e.latestEntry!.label == 'nur-label');
      expect(second.latestEntry!.tags, '');
      expect(second.latestEntry!.content, '');
      expect(second.latestEntry!.createTime,
          DateTime(2021, 1, 1).toIso8601String());
      expect(dst.allEntries.length, 2);
    });

    test('toCSV writes header and skips deleted entries', () {
      var src = UltracipherDatabase();
      var live = src.addEntry()
        ..addNewVersion(Entry(
            label: 'live',
            tags: 't',
            content: 'c',
            createTime: DateTime(2020, 1, 1).toIso8601String()));
      src.deleteEntry(src.addEntry()
        ..addNewVersion(Entry(label: 'gone', tags: '', content: '')));

      var lines = LineSplitter.split(src.toCSV()).toList();
      expect(lines.length, 2);
      expect(lines[0], 'id,create date,name,tags,body');
      expect(lines[1],
          '${live.id},${DateTime(2020, 1, 1).toIso8601String()},live,t,c');
    });

    test('Header row is skipped', () {
      var csv = 'id,create date,name,tags,body\n'
          'x,2024-01-01T10:00:00.000,label,tags,body\n';
      var db = UltracipherDatabase();
      expect(db.importFromCsv(csv).count, 1);
      expect(db.getEntryWhitId('x')!.latestEntry!.label, 'label');
    });

    test('Header detection trims and ignores case', () {
      var csv = ' ID ,Create Date,name,tags,body\n'
          'x,2024-01-01T10:00:00.000,label,tags,body\n';
      expect(UltracipherDatabase().importFromCsv(csv).count, 1);
    });

    test('Header only yields no entries', () {
      expect(UltracipherDatabase()
          .importFromCsv('id,create date,name,tags,body\n')
          .count, 0);
    });

    test('Empty date cell sets createTime to now', () {
      var before = DateTime.now();
      var db = UltracipherDatabase();
      db.importFromCsv('id,create date,name,tags,body\nx,,label,tags,body\n');
      var after = DateTime.now();
      var entry = db.getEntryWhitId('x')!;
      var created = entry.latestEntry!.createDateTime;
      expect(created.isBefore(before), false);
      expect(created.isAfter(after), false);
      expect(entry.latestEntry!.createTime.endsWith('Z'), isTrue);
    });

    test('Wrong column count throws without partial import', () {
      var db = UltracipherDatabase();
      db.addEntry().addNewVersion(Entry(label: 'existing'));
      var countBefore = db.allEntries.length;
      var csv = 'create date,name,tags,body\n'
          '2024-01-01T10:00:00.000,a,b,c\n'
          '2024-01-02T10:00:00.000,a,b,c\n'
          '2024-01-03T10:00:00.000,a,b\n';
      expect(
          () => db.importFromCsv(csv),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('CSV record 4: 3 columns instead of 4'))));
      expect(db.allEntries.length, countBefore);
    });

    test('Unparseable date throws without partial import', () {
      var db = UltracipherDatabase();
      db.addEntry().addNewVersion(Entry(label: 'existing'));
      var countBefore = db.allEntries.length;
      var csv = 'create date,name,tags,body\n'
          '2024-01-01T10:00:00.000,a,b,c\n'
          '2024-01-02T10:00:00.000,a,b,c\n'
          'kein Datum,a,b,c\n';
      expect(
          () => db.importFromCsv(csv),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('CSV record 4: date not readable'))));
      expect(db.allEntries.length, countBefore);
    });
  });

  test('Search ignores case in both directions', () {
    var d = UltracipherDatabase();
    d.addEntry().addNewVersion(
        Entry(label: 'Test', tags: 'GroßBuchstabe', content: 'Inhalt'));
    expect(d.getEntries(searchTerm: 'test').length, 1);
    expect(d.getEntries(searchTerm: 'TEST').length, 1);
    expect(d.getEntries(searchTerm: 'tEsT').length, 1);
    expect(d.getEntries(searchTerm: 'großbuchstabe').length, 1);
    expect(d.getEntries(searchTerm: 'inhalt').length, 1);
    expect(d.getEntries(searchTerm: 'nope').length, 0);
  });

  test('Find entry', () {
    var entries = db.getEntries();
    expect(entries.length, 3);

    entries = db.getEntries(searchTerm: "labeL1");
    expect(entries.length, 1);
    expect(entries[0].latestEntry!.content, 'con ten t');

    entries = db.getEntries(searchTerm: "tag2");
    expect(entries.length, 1);
    expect(entries[0].latestEntry!.content, 'con ten t');

    entries = db.getEntries(searchTerm: "more");
    expect(entries.length, 1);
    expect(entries[0].latestEntry!.content, 'more con ten t');

    entries = db.getEntries(searchTerm: "label more");
    expect(entries.length, 2);
    expect(entries[0].latestEntry!.content, 'more con ten t');
    expect(entries[1].latestEntry!.content, 'con ten t');

    entries = db.getEntries(searchTerm: "deleted");
    expect(entries.length, 0);

    // Geloeschte Eintraege sind weg und nur ueber ihre id in der Liste.
    expect(db.getEntryWhitId(deletedId1), t.isNull);
    expect(db.getEntryWhitId(deletedId2), t.isNull);
    expect(db.deletions.keys, t.unorderedEquals([deletedId1, deletedId2]));
  });

  test('VersionedEntry.fromJson tolerates missing versions key', () {
    var ve = VersionedEntry.fromJson({'id': 'x'});
    expect(ve.versions, t.isEmpty);
  });

  test('VersionedEntry.fromJson tolerates null versions', () {
    var ve = VersionedEntry.fromJson({'id': 'x', 'versions': null});
    expect(ve.versions, t.isEmpty);
  });

  test('VersionedEntry.fromJson throws on wrong-typed versions', () {
    expect(() => VersionedEntry.fromJson({'id': 'x', 'versions': 'CORRUPT'}),
        t.throwsA(t.isA<FormatException>()));
    expect(() => VersionedEntry.fromJson({'id': 'x', 'versions': 42}),
        t.throwsA(t.isA<FormatException>()));
    expect(() => VersionedEntry.fromJson({'id': 'x', 'versions': {}}),
        t.throwsA(t.isA<FormatException>()));
  });

  test('UltracipherDatabase.fromJson tolerates missing/null deleted_time', () {
    var d = UltracipherDatabase.fromJson({
      'entries': [
        {'id': 'x'},
        {'id': 'y', 'deleted_time': null}
      ]
    });
    expect(d.allEntries.length, 2);
    expect(d.deletions, t.isEmpty);
  });

  test('UltracipherDatabase.fromJson ignores a legacy deleted_time', () {
    var d = UltracipherDatabase.fromJson({
      'entries': [
        {'id': 'x', 'deleted_time': '2024-05-01T00:00:00.000Z'},
        {'id': 'y', 'deleted_time': 42}
      ]
    });
    expect(d.allEntries.map((e) => e.id), t.equals(['x', 'y']));
    expect(d.deletions, t.isEmpty);
    expect(jsonEncode(d.toJson()), t.isNot(t.contains('deleted_time')));
  });

  group(['Test ObfuscatedString'], (){
    test('Contains', (){
      var es = ObfuscatedString('test');
      expect(es.contains("bla"), false);
      expect(es.contains('te'), true);
      expect(es.contains('st'), true);
      expect(es.contains('ST'), false);
    });
  });
  test('various', () {
    var codeUnits = "test".codeUnits;
    var s = String.fromCharCodes(codeUnits);
    print(s);
  });
}
