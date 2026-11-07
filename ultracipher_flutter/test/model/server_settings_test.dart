// Tests des Sync-Server-Zweigs im settings-Register: `server` neben `github`,
// LWW-Merge, Tie-Break, fehlender Schluessel (aeltere Datenbanken), Rundreise.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ultracipher_flutter/src/model/model.dart';

GithubSettings gh(String token) =>
    GithubSettings(token: token, owner: 'o', repo: 'r', branch: 'main');
ServerSettings srv(String url) => ServerSettings(url: url);

final s1 = DateTime.utc(2024, 5, 1, 10);
final s2 = DateTime.utc(2024, 5, 2, 10);
final s3 = DateTime.utc(2024, 5, 3, 10);

UltracipherDatabase db(
    {GithubSettings? github, ServerSettings? server, DateTime? time}) {
  var d = UltracipherDatabase();
  if (time != null) d.setSettings(github: github, server: server, time: time);
  return d;
}

UltracipherDatabase copyOf(UltracipherDatabase d) =>
    UltracipherDatabase.fromJson(
        jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>);

UltracipherDatabase merged(UltracipherDatabase a, UltracipherDatabase b) =>
    copyOf(a)..merge(b);

void main() {
  test('server: Rundreise ueber toJson/fromJson, Zeit in UTC', () {
    var d = db(server: srv('https://example.test/ucdb'), time: s1);
    expect(d.toJson()['settings'], equals({
      'time': '2024-05-01T10:00:00.000Z',
      'github': null,
      'server': {'url': 'https://example.test/ucdb'},
    }));
    var back = copyOf(d);
    expect(back.settings, equals(d.settings));
    expect(back.settings!.server, equals(srv('https://example.test/ucdb')));
    expect(back.settings!.github, isNull);
    expect(back.hasSameContentAs(d), isTrue);
  });

  test('server: fehlt der Schluessel (aeltere Datenbank), ist er null; bei '
      'null wird er nicht geschrieben', () {
    var old = UltracipherDatabase.fromJson({
      'entries': [],
      'settings': {'time': '2024-05-01T10:00:00.000Z', 'github': null}
    });
    expect(old.settings!.server, isNull);
    expect(old.toJson()['settings'] as Map, isNot(contains('server')));
    expect(jsonEncode(old.toJson()['settings']),
        equals('{"time":"2024-05-01T10:00:00.000Z","github":null}'));

    var withGithub = db(github: gh('t'), time: s1);
    expect(withGithub.toJson()['settings'] as Map, isNot(contains('server')));

    // Ausdruecklich null wird wie fehlend gelesen.
    var explicitNull = UltracipherDatabase.fromJson({
      'entries': [],
      'settings': {
        'time': '2024-05-01T10:00:00.000Z',
        'github': null,
        'server': null
      }
    });
    expect(explicitNull.settings!.server, isNull);
  });

  test('server: fehlerhafter Wert -> FormatException ohne URL in der Meldung',
      () {
    const secretUrl = 'https://example.test/ucdb/SECRET-PATH';
    Object? failure(dynamic server) {
      try {
        UltracipherDatabase.fromJson({
          'entries': [],
          'settings': {
            'time': '2024-05-01T10:00:00.000Z',
            'github': null,
            'server': server
          }
        });
      } on FormatException catch (e) {
        return e;
      }
      return null;
    }

    for (var bad in <dynamic>[
      'text',
      7,
      {'url': 5},
      <String, dynamic>{},
    ]) {
      var e = failure(bad);
      expect(e, isA<FormatException>(), reason: '$bad');
    }
    expect(failure({'url': secretUrl}), isNull);
    expect(srv(secretUrl).toString(), isNot(contains('SECRET-PATH')));
    expect(db(server: srv(secretUrl), time: s1).settings.toString(),
        isNot(contains('SECRET-PATH')));
  });

  test('server: die neuere Zeit gewinnt in beide Richtungen, auch GitHub <-> '
      'Server und Entfernen', () {
    var github = db(github: gh('t1'), time: s1);
    var server = db(server: srv('https://a.test'), time: s2);
    var removed = db(time: s3);
    for (var r in [merged(github, server), merged(server, github)]) {
      expect(r.settings!.server, equals(srv('https://a.test')));
      expect(r.settings!.github, isNull);
      expect(r.settings!.time, equals(s2));
    }
    for (var r in [merged(server, removed), merged(removed, server)]) {
      expect(r.settings!.server, isNull);
      expect(r.settings!.github, isNull);
      expect(r.settings!.time, equals(s3));
    }
    // Ein aelteres "entfernt" verliert gegen den Server.
    var oldRemoved = db(time: s1.subtract(Duration(days: 1)));
    for (var r in [merged(server, oldRemoved), merged(oldRemoved, server)]) {
      expect(r.settings!.server, equals(srv('https://a.test')));
    }
    // Ein fehlendes Register verliert gegen jeden Wert.
    var none = db();
    expect(merged(none, server).settings, equals(server.settings));
    expect(merged(server, none).settings, equals(server.settings));
  });

  test('server: gleiche Zeit -> Tie-Break nach kanonischem JSON, '
      'richtungsunabhaengig', () {
    var a = db(server: srv('https://a.test'), time: s1);
    var b = db(server: srv('https://b.test'), time: s1);
    var ab = merged(a, b);
    var ba = merged(b, a);
    expect(ab.settings, equals(ba.settings));
    expect(ab.settings!.server, equals(srv('https://b.test')));

    // Server gegen GitHub gegen "entfernt" bei gleicher Zeit: eindeutig.
    var g = db(github: gh('t'), time: s1);
    var n = db(time: s1);
    var all = [a, b, g, n];
    DatabaseSettings? expected;
    for (var x in all) {
      for (var y in all) {
        for (var z in all) {
          var left = merged(merged(x, y), z);
          var right = merged(x, merged(y, z));
          expect(left.settings, equals(right.settings));
          expected ??= left.settings;
        }
      }
    }
    // Ohne server bleibt der Tie-Break wie vor dem neuen Feld: ein Wert
    // (Objekt, beginnt mit '{') schlaegt den JSON-Text 'null'.
    expect(merged(g, n).settings!.github, equals(gh('t')));
    expect(merged(n, g).settings!.github, equals(gh('t')));
    // Mit server ist die kanonische Form ein Objekt und schlaegt 'null'.
    expect(merged(a, n).settings!.server, equals(srv('https://a.test')));
    expect(merged(n, a).settings!.server, equals(srv('https://a.test')));
  });

  test('server: Merge ist kommutativ, assoziativ und idempotent bei '
      'verschiedenen Zeiten', () {
    var dbs = [
      db(github: gh('t1'), time: s1),
      db(server: srv('https://x.test'), time: s3),
      db(server: srv('https://y.test'), time: s2),
    ];
    var perms = [
      [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]
    ];
    for (var p in perms) {
      var left = merged(merged(dbs[p[0]], dbs[p[1]]), dbs[p[2]]);
      var right = merged(dbs[p[0]], merged(dbs[p[1]], dbs[p[2]]));
      expect(left.settings, equals(right.settings));
      expect(left.settings!.server, equals(srv('https://x.test')));
    }
    var a = dbs[1];
    expect(merged(a, a).settings, equals(a.settings));
  });

  test('server: hasSameContentAs und == beachten server', () {
    var a = db(server: srv('https://a.test'), time: s1);
    var b = db(server: srv('https://b.test'), time: s1);
    var none = db(time: s1);
    expect(a.hasSameContentAs(copyOf(a)), isTrue);
    expect(a.hasSameContentAs(b), isFalse);
    expect(a.hasSameContentAs(none), isFalse);
    expect(a.settings, isNot(equals(none.settings)));
    expect(a.settings.hashCode,
        equals(db(server: srv('https://a.test'), time: s1).settings.hashCode));
  });

  test('activeServer: server nur, solange kein github gesetzt ist', () {
    var s = srv('https://a.test');
    expect(db(server: s, time: s1).settings!.activeServer, s);
    expect(db(github: gh('t'), server: s, time: s1).settings!.activeServer,
        isNull);
    expect(db(github: gh('t'), time: s1).settings!.activeServer, isNull);
    expect(db(time: s1).settings!.activeServer, isNull);
  });

  test('setSettings: github und server ohne server-Angabe bleiben wie vorher',
      () {
    var d = UltracipherDatabase()..setSettings(github: gh('t'), time: s1);
    expect(d.settings!.server, isNull);
    d.setSettings(server: srv('https://a.test'), time: s2);
    expect(d.settings!.github, isNull);
    expect(d.settings!.server, equals(srv('https://a.test')));
  });
}
