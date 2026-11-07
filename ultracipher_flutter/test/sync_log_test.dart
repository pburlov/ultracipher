// Tests des Sync-Logs (sync_log.dart): Ringpuffer, Erfassung der GitHub-
// Antworten im GithubBackend (404 mit message/owner/repo/branch), die harte
// Regel "nie Geheimnisse ins Log" (Token, Inhalt, voller Name), die
// Statuswechsel in core.dart und der Bildschirm "Sync log" samt Copy/Clear.
// Kein Netz: http.MockClient.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/backend/github_backend.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
import 'package:ultracipher_flutter/src/backend/rest_backend.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/github_settings.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/sync.dart';
import 'package:ultracipher_flutter/src/sync_log.dart';
import 'package:ultracipher_flutter/src/sync_log_screen.dart';
import 'package:ultracipher_flutter/src/user_key_hash.dart';

import 'memoized_key_derivation.dart';

const _token = 'ghp_FAKE0123456789SECRETTOKENxyz';

/// 43 Zeichen wie ein echter Datenbankname (base64url).
const _name = 'QWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXo-_0123456';

const _plain = 'SECRET-PLAINTEXT-CONTENT';

final _t0 = DateTime.utc(2026, 11, 5, 12);

String _inner() => base64.encode(utf8.encode('CIPHERTEXT-$_plain'));
String _outer() => base64.encode(utf8.encode(_inner()));

http.Response _json(Object body, int status,
        {Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status, headers: headers);

GithubBackend _backend(http.Client client, SyncLog log) => GithubBackend(
    owner: 'someowner',
    repo: 'some-repo',
    token: _token,
    branch: 'some-branch',
    client: client,
    log: log);

SyncLog _log() => SyncLog(now: () => _t0);

void main() {
  useMemoizedKeyDerivation();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ring buffer', () {
    test('keeps the newest 200 entries, newest first', () {
      var log = _log();
      for (var i = 0; i < 205; i++) {
        log.record(operation: 'op$i', result: 'ok');
      }
      expect(log.length, 200);
      var entries = log.entries;
      expect(entries.first.operation, 'op204');
      expect(entries.last.operation, 'op5');
    });

    test('clear empties it and notifies; the clock is injectable', () {
      var log = _log();
      var notified = 0;
      log.addListener(() => notified++);
      log.record(operation: 'x', result: 'ok');
      expect(log.entries.single.time, _t0);
      expect(log.toText(), startsWith('2026-11-05T12:00:00.000Z'));
      log.clear();
      expect(log.length, 0);
      expect(log.toText(), '');
      expect(notified, 2);
    });

    test('never throws, even when a listener does', () {
      var log = _log();
      log.addListener(() => throw StateError('listener'));
      log.record(operation: 'x', result: 'ok');
      log.clear();
      expect(log.toText(), '');
    });

    test('never throws with a clock that throws', () {
      var log = SyncLog(now: () => throw StateError('clock'));
      log.record(operation: 'x', result: 'ok');
      log.clear();
      expect(log.toText(), '');
      expect(log.length, 0);
    });

    test('texts are clipped to 300 characters and kept to one line', () {
      var log = _log();
      log.record(
          operation: 'put', result: 'httpError', message: 'a\nb ${'x' * 500}');
      var message = log.entries.single.message!;
      expect(message.length, 300);
      expect(message, startsWith('a b x'));
    });
  });

  group('GithubBackend logging', () {
    test(
        'a 404 on read records message, documentation_url, owner, repo, '
        'branch, the masked path and the harmless headers', () async {
      var log = _log();
      var client = MockClient((request) async => _json(
          {
            'message': 'Not Found',
            'documentation_url':
                'https://docs.github.com/rest/repos/contents#get-repository-content',
          },
          404,
          headers: {
            'x-github-request-id': 'ABCD:1234',
            'x-ratelimit-remaining': '4999',
            'x-accepted-github-permissions': 'contents=read',
            'x-oauth-scopes': 'gist, read:user',
            'x-accepted-oauth-scopes': 'repo',
            'github-authentication-token-expiration': '2026-12-01 10:00:00 UTC',
            'set-cookie': 'SECRETCOOKIE',
            'x-other': 'IGNORED',
          }));
      var data = await _backend(client, log).read(_name);
      expect(data.isEmpty, isTrue); // Verhalten unveraendert: 404 = leer

      var e = log.entries.single;
      expect(e.operation, 'read file');
      expect(e.method, 'GET');
      expect(e.endpoint, 'contents');
      expect(e.status, 404);
      expect(e.result, 'remoteMissing');
      expect(e.message, 'Not Found');
      expect(e.documentationUrl, contains('docs.github.com'));
      expect([e.owner, e.repo, e.branch],
          ['someowner', 'some-repo', 'some-branch']);
      expect(e.path, 'QWJjZG...<.txt');
      expect(e.headers, {
        'x-github-request-id': 'ABCD:1234',
        'x-ratelimit-remaining': '4999',
        'x-accepted-github-permissions': 'contents=read',
        'x-oauth-scopes': 'gist, read:user',
        'x-accepted-oauth-scopes': 'repo',
        'github-authentication-token-expiration': '2026-12-01 10:00:00 UTC',
      });
      var text = log.toText();
      expect(text, contains('read file  GET contents  404  remoteMissing'));
      expect(
          text,
          contains('owner=someowner repo=some-repo '
              'branch=some-branch path=QWJjZG...<.txt'));
      expect(text, isNot(contains('SECRETCOOKIE')));
      expect(text, isNot(contains('IGNORED')));
    });

    test(
        'put and delete map their results; a non-JSON body leaves message '
        'and documentation_url out', () async {
      var log = _log();
      var status = 404;
      var body = 'plain not found';
      var client = MockClient((_) async => http.Response(body, status));
      var backend = _backend(client, log);

      await expectLater(backend.write(_name, Uint8List.fromList([1, 2, 3])),
          throwsA(isA<RemoteBackendException>()));
      var put = log.entries.first;
      expect([put.operation, put.method, put.status, put.result],
          ['put', 'PUT', 404, 'notFound']);
      expect(put.message, isNull);
      expect(put.documentationUrl, isNull);

      await expectLater(backend.delete(_name, 'sha1'),
          throwsA(isA<RemoteConflictException>()));
      expect(log.entries.first.result, 'conflict');

      status = 422;
      body = jsonEncode(
          {'message': 'Invalid request.\n\n"sha" wasn\'t supplied.'});
      await expectLater(backend.write(_name, Uint8List.fromList([1])),
          throwsA(isA<RemoteConflictException>()));
      expect(log.entries.first.result, 'conflict');
      expect(log.entries.first.message,
          'Invalid request. "sha" wasn\'t supplied.');

      status = 401;
      await expectLater(backend.write(_name, Uint8List.fromList([1])),
          throwsA(isA<RemoteAuthException>()));
      expect(log.entries.first.result, 'authRequired');

      status = 429;
      await expectLater(backend.delete(_name, 'sha1'),
          throwsA(isA<RemoteRateLimitException>()));
      expect(log.entries.first.result, 'rateLimit');

      status = 200;
      body = jsonEncode({
        'content': {'sha': 'newsha'}
      });
      await backend.write(_name, Uint8List.fromList([1]));
      var ok = log.entries.first;
      expect([ok.status, ok.result, ok.message], [200, 'ok', null]);
    });

    test('a 404 on the blob request is logged as its own entry', () async {
      var log = _log();
      var client = MockClient((request) async {
        if (request.url.path.contains('/git/blobs/')) {
          return _json({'message': 'Not Found'}, 404);
        }
        return _json(
            {'sha': 'abc', 'size': 5, 'encoding': 'none', 'content': ''}, 200);
      });
      await expectLater(_backend(client, log).read(_name),
          throwsA(isA<RemoteBackendException>()));
      var entries = log.entries;
      expect(entries.map((e) => e.operation), ['read blob', 'read file']);
      expect(entries.first.endpoint, 'git/blobs');
      expect(entries.first.status, 404);
      expect(entries.first.result, 'notFound');
      expect(entries.first.message, 'Not Found');
    });

    test('transport errors and timeouts are logged by type only', () async {
      var log = _log();
      var client = MockClient((request) async =>
          throw http.ClientException('boom $_token', request.url));
      await expectLater(_backend(client, log).read(_name),
          throwsA(isA<RemoteBackendException>()));
      var e = log.entries.single;
      expect(e.result, 'network');
      expect(e.detail, 'error: ClientException');

      var hanging = MockClient((_) => Future<http.Response>.delayed(
          const Duration(seconds: 5), () => http.Response('', 200)));
      var backend = GithubBackend(
          owner: 'o',
          repo: 'r',
          token: _token,
          client: hanging,
          log: log,
          requestTimeout: const Duration(milliseconds: 20));
      await expectLater(
          backend.read(_name), throwsA(isA<RemoteTimeoutException>()));
      expect(log.entries.first.result, 'timeout');
      expect(log.entries.where((e) => e.result == 'timeout').length, 1);
    });

    test('NEVER token, content, URL, query or the full name in the log',
        () async {
      var log = _log();
      var echo = '$_token $_name ${_inner()}';
      var client = MockClient((request) async {
        var path = request.url.path;
        if (request.method == 'GET' && path.contains('/git/blobs/')) {
          return _json({'encoding': 'base64', 'content': _outer()}, 200);
        }
        if (request.method == 'GET' && path.endsWith('/user')) {
          return _json({'login': 'someowner'}, 200);
        }
        if (request.method == 'GET' && path.endsWith('big.txt')) {
          return _json(
              {'sha': 'abc', 'size': 10, 'encoding': 'none', 'content': ''},
              200);
        }
        if (request.method == 'GET') {
          return _json({
            'sha': 'abc',
            'size': 10,
            'encoding': 'base64',
            'content': _outer(),
            'name': '$_name.txt',
            'download_url': 'https://x/?token=$_token',
          }, 200);
        }
        if (request.method == 'PUT') {
          // Fehler, deren Meldung Geheimnisse wiederholt.
          return _json({
            'message': 'Bad request: $echo',
            'documentation_url':
                'https://docs.github.com/x?access_token=$_token',
          }, 422);
        }
        throw http.ClientException('failed for $_token', request.url);
      });
      var backend = GithubBackend(
          owner: 'someowner',
          repo: 'some-repo',
          token: _token,
          branch: 'main',
          client: client,
          log: log);

      var data = await backend.read(_name);
      expect(data.isEmpty, isFalse);
      await expectLater(
          backend.write(_name, Uint8List.fromList(utf8.encode(_plain)),
              version: 'abc'),
          throwsA(isA<RemoteConflictException>()));
      await expectLater(
          backend.delete(_name, 'abc'), throwsA(isA<RemoteBackendException>()));
      await GithubBackend.resolveOwner(_token, client: client, log: log);
      // Der Blob-Weg (Datei ueber 1 MB).
      await GithubBackend(
              owner: 'o',
              repo: 'r',
              token: _token,
              pathMapper: (_) => 'big.txt',
              client: client,
              log: log)
          .read(_name);

      var text = log.toText();
      expect(log.length, 6);
      expect(
          text,
          contains('message: Bad request: [redacted] [redacted] '
              '[redacted]'));
      for (var secret in [
        _token,
        'ghp_FAKE',
        'Bearer',
        'Authorization',
        _name,
        _name.substring(0, 10),
        _inner(),
        _outer(),
        _plain,
        'CIPHERTEXT',
        'access_token',
        'ref=',
        'api.github.com',
        '?',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      // Die ersten 6 Zeichen des Namens und die Endung sind gewollt.
      expect(text, contains('path=QWJjZG...<.txt'));
    });

    test(
        'an echoed token or name at the clip boundary does not leak a '
        'fragment (scrub first, then clip)', () async {
      for (var secret in [_token, _name]) {
        var log = _log();
        var client = MockClient((_) async => _json({
              'message': '${'word ' * 58} $secret',
              'documentation_url':
                  'https://docs.github.com/${'seg.' * 70}$secret',
            }, 500));
        await expectLater(_backend(client, log).write(_name, Uint8List(1)),
            throwsA(isA<RemoteBackendException>()));
        var text = log.toText();
        expect(text, contains('word word'));
        expect(text, contains('seg.seg.'));
        expect(text, isNot(contains(_token.substring(0, 8))));
        expect(text, isNot(contains(_name.substring(0, 10))));
      }
    });

    test('a 2xx body is never read: its message field stays out', () async {
      var log = _log();
      var client = MockClient((_) async => _json({
            'message': 'MESSAGE-IN-2XX',
            'documentation_url': 'https://docs.github.com/DOC-IN-2XX',
            'content': {'sha': 'newsha'},
          }, 200));
      await _backend(client, log).write(_name, Uint8List(1));
      var e = log.entries.single;
      expect([e.result, e.message, e.documentationUrl], ['ok', null, null]);
      expect(log.toText(), isNot(contains('IN-2XX')));
    });

    test('a late answer after the timeout adds no second entry', () async {
      var log = _log();
      var slow = MockClient((_) => Future<http.Response>.delayed(
          const Duration(milliseconds: 100), () => http.Response('', 200)));
      var backend = GithubBackend(
          owner: 'o',
          repo: 'r',
          token: _token,
          client: slow,
          log: log,
          requestTimeout: const Duration(milliseconds: 10));
      await expectLater(
          backend.read(_name), throwsA(isA<RemoteTimeoutException>()));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(log.entries.map((e) => e.result), ['timeout']);
    });

    test(
        'an answer arriving after the log was cleared (session switch) '
        'adds no entry', () async {
      var log = _log();
      var gate = Completer<void>();
      var client = MockClient((_) async {
        await gate.future;
        return _json({'message': 'Not Found'}, 404);
      });
      var pending = _backend(client, log).read(_name);
      await Future<void>.delayed(Duration.zero);
      log.clear();
      gate.complete();
      await pending;
      expect(log.length, 0);
      // Ein normaler Eintrag nach dem Leeren geht durch.
      log.record(operation: 'status', result: 'syncing');
      expect(log.length, 1);
    });

    test('owner, repo and branch are scrubbed too (token typed into a field)',
        () async {
      var log = _log();
      var client =
          MockClient((_) async => _json({'message': 'Not Found'}, 404));
      var backend = GithubBackend(
          owner: 'ow',
          repo: _token,
          token: _token,
          branch: 'x\n${_token.substring(0, 12)}',
          client: client,
          log: log);
      await backend.read(_name);
      var text = log.toText();
      expect(text, contains('repo=[redacted]'));
      expect(text, isNot(contains(_token.substring(0, 8))));
    });

    test(
        'the exact database name is removed from short fields (no base64 '
        'rule there): docs url, owner, repo, branch', () async {
      var log = _log();
      var client = MockClient((_) async => _json({
            'message': 'm',
            'documentation_url': 'https://docs.github.com/$_name',
          }, 404));
      var backend = GithubBackend(
          owner: _name,
          repo: 'x$_name',
          token: _token,
          branch: _name,
          client: client,
          log: log);
      await backend.read(_name);
      var text = log.toText();
      expect(text, isNot(contains(_name)));
      expect(text, isNot(contains(_name.substring(0, 10))));
      expect(log.entries.single.documentationUrl,
          'https://docs.github.com/[redacted]');
    });

    test('a token in a whitelisted header is scrubbed', () async {
      var log = _log();
      var client = MockClient((_) async => _json({'message': 'm'}, 404,
          headers: {
            'x-github-request-id': 'id $_token',
            'x-oauth-scopes': _name
          }));
      await _backend(client, log).read(_name);
      var text = log.toText();
      expect(text, contains('x-github-request-id=id [redacted]'));
      expect(text, isNot(contains(_token.substring(0, 8))));
      expect(text, isNot(contains(_name)));
    });

    test('a blob answer arriving after the log was cleared adds no entry', () async {
      var log = _log();
      var gate = Completer<void>();
      var client = MockClient((request) async {
        if (request.url.path.contains('/git/blobs/')) {
          await gate.future;
          return _json({'message': 'Not Found'}, 404);
        }
        return _json(
            {'sha': 'abc', 'size': 5, 'encoding': 'none', 'content': ''}, 200);
      });
      var pending = _backend(client, log).read(_name);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      log.clear(); // Sitzungswechsel, nachdem die Datei-Antwort da war
      gate.complete();
      await expectLater(pending, throwsA(isA<RemoteBackendException>()));
      expect(log.length, 0);
    });

    group('scrub', () {
      Future<String> messageFor(String message, {String token = _token}) async {
        var log = _log();
        var client = MockClient((_) async => _json({'message': message}, 500));
        var backend = GithubBackend(
            owner: 'o', repo: 'r', token: token, client: client, log: log);
        await expectLater(backend.write(_name, Uint8List(1)),
            throwsA(isA<RemoteBackendException>()));
        return log.entries.single.message ?? '';
      }

      test('C: the percent-encoded token', () async {
        var odd = 'tok/en+SECRET value#12345';
        var text = await messageFor('see ${Uri.encodeComponent(odd)} here',
            token: odd);
        expect(text, isNot(contains('SECRET')));
        expect(text, isNot(contains('%20value')));
        expect(text, startsWith('see [redacted] here'));
      });

      test(
          'D: every piece of the token from 8 characters, and token '
          'patterns', () async {
        var text = await messageFor('a ${_token.substring(5, 20)} b '
            'ghp_OTHER0123456789 c github_pat_11ABC_xyz d');
        expect(text, isNot(contains(_token.substring(5, 13))));
        expect(text, isNot(contains('OTHER')));
        expect(text, isNot(contains('github_pat')));
        expect(text, startsWith('a '));
      });

      test('E: a token split by a line break', () async {
        var text = await messageFor(
            '${_token.substring(0, 16)}\n${_token.substring(16)}');
        expect(text, isNot(contains(_token.substring(0, 8))));
        expect(text, isNot(contains(_token.substring(16, 24))));

        // In Stuecken unter 8 Zeichen: nur der Vergleich ohne Whitespace
        // erkennt es, und dann faellt die ganze Meldung weg.
        var pieces = [
          for (var i = 0; i < _token.length; i += 6)
            _token.substring(i, i + 6 > _token.length ? _token.length : i + 6)
        ];
        expect(await messageFor('x ${pieces.join('\n')} y'), '[redacted]');
      });

      test('documentation_url: only docs.github.com, kept even when long',
          () async {
        var log = _log();
        var long = 'https://docs.github.com/rest/repos/'
            'a-very-long-documentation-path-segment-over-forty-characters'
            '?token=$_token';
        var url = long;
        var client = MockClient((_) async =>
            _json({'message': 'm', 'documentation_url': url}, 404));
        var backend = _backend(client, log);
        await backend.read(_name);
        expect(log.entries.first.documentationUrl, long.split('?').first);
        url = 'https://evil.example/docs';
        await backend.read(_name);
        expect(log.entries.first.documentationUrl, isNull);
        expect(log.toText(), isNot(contains(_token)));
      });
    });

    test('the log does not change what the backend returns or throws',
        () async {
      var client = MockClient((_) async => _json({'message': 'Bad'}, 500));
      var plain =
          GithubBackend(owner: 'o', repo: 'r', token: _token, client: client);
      var logged = _backend(client, _log());
      Object? a, b;
      try {
        await plain.read(_name);
      } catch (e) {
        a = e;
      }
      try {
        await logged.read(_name);
      } catch (e) {
        b = e;
      }
      expect(a.toString(), 'GitHub request failed with status 500');
      expect(b.toString(), a.toString());
      expect(b.toString(), isNot(contains(_token)));
    });
  });

  group('RestBackend logging', () {
    const secretPath = 'SECRET-PATH-SEGMENT-0123456789';
    const url = 'https://sync.example.test/ucdb/$secretPath';

    RestBackend rest(http.Client client, SyncLog log,
            {Duration timeout = const Duration(seconds: 5)}) =>
        RestBackend(
            url: url, client: client, log: log, requestTimeout: timeout);

    test('requests are logged with method, status, result, host and the '
        'masked name', () async {
      var log = _log();
      var statuses = <String, int>{'GET': 404, 'PUT': 201, 'DELETE': 412};
      var client = MockClient((request) async => http.Response(
          '', statuses[request.method]!,
          headers: {'ETag': '"7"', 'Retry-After': '9'}));
      var backend = rest(client, log);

      await backend.read(_name);
      await backend.write(_name, Uint8List.fromList([1, 2]));
      await expectLater(
          backend.delete(_name, '3'), throwsA(isA<RemoteConflictException>()));
      statuses['GET'] = 429;
      await expectLater(
          backend.read(_name), throwsA(isA<RemoteRateLimitException>()));
      statuses['GET'] = 500;
      await expectLater(
          backend.read(_name), throwsA(isA<RemoteBackendException>()));

      var entries = log.entries.toList().reversed.toList();
      expect(entries.map((e) => e.operation),
          ['read file', 'put', 'delete', 'read file', 'read file']);
      expect(entries.map((e) => e.method),
          ['GET', 'PUT', 'DELETE', 'GET', 'GET']);
      expect(entries.map((e) => e.status), [404, 201, 412, 429, 500]);
      expect(entries.map((e) => e.result), [
        'remoteMissing',
        'ok',
        'conflict',
        'rateLimit',
        'httpError',
      ]);
      expect(entries.every((e) => e.host == 'sync.example.test'), isTrue);
      expect(entries.every((e) => e.endpoint == 'file'), isTrue);
      expect(entries.every((e) => e.path == 'QWJjZG...<'), isTrue);
      expect(entries[3].headers, {'retry-after': '9'});
      expect(entries.first.toText(), contains('host=sync.example.test'));
    });

    test('NEVER URL (path), name, content, response body or headers', () async {
      var log = _log();
      var echo = '$url $_name ${_inner()} $_plain';
      var client = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response.bytes(utf8.encode('CIPHERTEXT-$_plain'), 200,
              headers: {'ETag': '"7"', 'X-Echo': echo});
        }
        if (request.method == 'PUT') {
          // Ein eigener Server kann in eine Fehlerantwort schreiben, was er will.
          return http.Response('Bad request: $echo', 500,
              headers: {'Retry-After': echo, 'X-Echo': echo});
        }
        throw http.ClientException('failed for $url $_name', request.url);
      });
      var backend = rest(client, log);

      await backend.read(_name);
      await expectLater(
          backend.write(_name, Uint8List.fromList(utf8.encode(_plain))),
          throwsA(isA<RemoteBackendException>()));
      await expectLater(
          backend.delete(_name, '1'), throwsA(isA<RemoteBackendException>()));

      var text = log.toText();
      expect(log.length, 3);
      for (var secret in [
        secretPath,
        'ucdb',
        _name,
        _name.substring(0, 10),
        _inner(),
        _plain,
        'CIPHERTEXT',
        'Bad request',
        'X-Echo',
        'https://',
        '?',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(text, contains('host=sync.example.test'));
      expect(text, contains('path=QWJjZG...<'));
      expect(text, contains('error: ClientException'));
    });

    test('an invalid URL logs nothing and the message has no URL', () async {
      var log = _log();
      var backend = RestBackend(
          url: 'http://example.test/$secretPath',
          client: MockClient((_) async => http.Response('', 200)),
          log: log);
      await expectLater(
          backend.read(_name), throwsA(isA<RemoteBackendException>()));
      expect(log.length, 0);
    });

    test('a timeout is one entry; a late answer adds no second', () async {
      var log = _log();
      var hanging = MockClient((_) => Future<http.Response>.delayed(
          const Duration(milliseconds: 80),
          () => http.Response('', 200, headers: {'etag': '"1"'})));
      var backend =
          rest(hanging, log, timeout: const Duration(milliseconds: 20));
      await expectLater(
          backend.read(_name), throwsA(isA<RemoteTimeoutException>()));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(log.length, 1);
      expect(log.entries.single.result, 'timeout');
      expect(log.entries.single.host, 'sync.example.test');
      expect(log.toText(), isNot(contains(secretPath)));
    });

    test('a 200 without ETag is logged as parseError, status only', () async {
      var log = _log();
      var client = MockClient((_) async => http.Response('data', 200));
      await expectLater(rest(client, log).read(_name),
          throwsA(isA<RemoteBackendException>()));
      var results = log.entries.map((e) => e.result).toList();
      expect(results, ['parseError', 'ok']);
      expect(log.toText(), isNot(contains(secretPath)));
    });

    test('an answer arriving after the log was cleared adds no entry',
        () async {
      var log = _log();
      var gate = Completer<void>();
      var client = MockClient((_) async {
        await gate.future;
        return http.Response('', 404);
      });
      var pending = rest(client, log).read(_name);
      log.clear();
      gate.complete();
      await pending;
      expect(log.length, 0);
    });
  });

  group('sync status and the app', () {
    test(
        'status changes are logged with the existing error text, repeats '
        'are not', () {
      var app = UltracipherApp();
      app.syncLog.now = () => _t0;
      app.syncStatus.value = SyncStatus.syncing;
      app.syncStatus.value = SyncStatus.syncing;
      app.syncStatus.value = const SyncStatus(SyncState.remoteMissing,
          error: 'Database no longer found on GitHub - passphrase changed?');
      var entries = app.syncLog.entries;
      expect(entries.length, 2);
      expect(entries.first.operation, 'status');
      expect(entries.first.result, 'remoteMissing');
      expect(
          entries.first.detail,
          'syncing -> remoteMissing: Database no longer found on GitHub - '
          'passphrase changed?');
      expect(entries.last.detail, 'noRemote -> syncing');
    });

    test('the log is cleared on a session switch, close and erase', () async {
      SharedPreferences.setMockInitialValues({});
      var app = UltracipherApp();
      await app.init();
      void fill() =>
          app.syncLog.record(operation: 'read file', result: 'remoteMissing');

      fill();
      await app.createDatabase('passphrase A');
      expect(app.syncLog.length, 0, reason: 'session switch');

      fill();
      app.closeDatabase();
      expect(app.syncLog.length, 0, reason: 'close');

      fill();
      await app.eraseLocalData();
      expect(app.syncLog.length, 0, reason: 'erase');
    });

    test('a passphrase change starts a fresh log', () async {
      SharedPreferences.setMockInitialValues({});
      var app = UltracipherApp();
      await app.init();
      await app.createDatabase('passphrase A');
      app.syncLog.record(operation: 'read file', result: 'remoteMissing');
      await app.changeDatabasePassphrase(
          oldPassphrase: 'passphrase A', newPassphrase: 'passphrase B');
      expect(app.syncLog.length, 0);
    });

    test(
        'a transport error with the token in it does not reach the status '
        'text or the log', () async {
      SharedPreferences.setMockInitialValues({});
      var app = UltracipherApp();
      await app.init();
      var db = UltracipherDatabase()
        ..setSettings(
            github: GithubSettings(
                token: _token, owner: 'o', repo: 'r', branch: 'main'));
      var key = await app.deriveRoot('passphrase A');
      app.backendForSettings = (github, root) => github == null
          ? null
          : GithubBackend(
              owner: github.owner,
              repo: github.repo,
              token: github.token,
              branch: github.branch,
              log: app.syncLog,
              client: MockClient((request) async =>
                  throw http.ClientException('boom $_token', request.url)));
      await app.importEncryptedText(
          base64.encode(UltracipherApp.encryptDatabase(db, key)),
          'passphrase A');
      var status = await app.syncNow();
      expect(status.state, SyncState.notSynced);
      expect(status.error, isNot(contains(_token)));
      var text = app.syncLog.toText();
      expect(text, contains('notSynced'));
      expect(text, contains('network'));
      expect(text, isNot(contains(_token.substring(0, 8))));
    });

    test('a real session logs its requests into the app log', () async {
      SharedPreferences.setMockInitialValues({});
      var app = UltracipherApp();
      await app.init();
      var key = await app.deriveRoot('passphrase A');
      var db = UltracipherDatabase()
        ..setSettings(
            github: GithubSettings(
                token: _token, owner: 'o', repo: 'r', branch: 'main'));
      await app.importEncryptedText(
          base64.encode(UltracipherApp.encryptDatabase(db, key)),
          'passphrase A');
      expect((app.remoteBackend as GithubBackend).log, same(app.syncLog));
      await app.syncNow();
      var operations = app.syncLog.entries.map((e) => e.operation);
      expect(operations, contains('read file'));
      expect(operations, contains('status'));
      var text = app.syncLog.toText();
      expect(text, isNot(contains(_token)));
      expect(text, isNot(contains(databaseName(key))));
      expect(text, contains(databaseName(key).substring(0, 6)));
    });
  });

  group('screen', () {
    final copied = <String>[];

    setUp(() {
      copied.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets(
        'shows the entries newest first; Copy puts one text on the '
        'clipboard; Clear empties it', (tester) async {
      var log = _log();
      log.record(
          operation: 'read file',
          method: 'GET',
          endpoint: 'contents',
          status: 404,
          result: 'remoteMissing',
          message: 'Not Found',
          owner: 'ow',
          repo: 're',
          branch: 'br');
      log.record(operation: 'status', result: 'syncing', detail: 'a -> b');
      await tester.pumpWidget(MaterialApp(home: SyncLogScreen(log: log)));

      expect(find.text('Sync log'), findsOneWidget);
      expect(
          find.text('Contains account, repository and branch; check before '
              'sharing.'),
          findsOneWidget);
      expect(find.textContaining('message: Not Found', findRichText: true),
          findsOneWidget);
      var newest =
          tester.getTopLeft(find.textContaining('a -> b', findRichText: true));
      var oldest = tester
          .getTopLeft(find.textContaining('read file', findRichText: true));
      expect(newest.dy, lessThan(oldest.dy));

      await tester.tap(find.byKey(const Key('syncLogCopy')));
      await tester.pump();
      expect(copied, [log.toText()]);
      expect(copied.single, contains('owner=ow repo=re branch=br'));
      expect(find.text('Sync log copied'), findsOneWidget);

      await tester.tap(find.byKey(const Key('syncLogClear')));
      await tester.pump();
      expect(log.length, 0);
      expect(find.textContaining('No entries yet'), findsOneWidget);
    });

    testWidgets('the GitHub settings reach it, with no error present',
        (tester) async {
      var app = UltracipherApp.instance;
      app.syncLog.clear();
      app.syncLog.record(operation: 'put', result: 'ok', status: 200);
      await tester.pumpWidget(MaterialApp(home: GithubSettingsScreen()));
      await tester.tap(find.byKey(const Key('syncLogButton')));
      await tester.pumpAndSettle();
      expect(find.byType(SyncLogScreen), findsOneWidget);
      expect(find.textContaining('put  ', findRichText: true), findsOneWidget);
      app.syncLog.clear();
    });
  });
}
