// Tests von RestBackend (lib/src/backend/rest_backend.dart) gegen
// http.testing.MockClient und den protokolltreuen FakeRestServer: Abbildung
// aller Statuswerte, gesendete Header und URL, Fehlerfaelle ohne ETag/Inhalt,
// Timeout/Abbruch, URL-Pruefung. Kein Netz.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
import 'package:ultracipher_flutter/src/backend/rest_backend.dart';

import 'fake_rest_server.dart';

/// 43 Zeichen wie ein echter Datenbankname (base64url).
const _name = 'QWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXo-_0123456';
const _url = 'https://sync.example.test/ucdb';

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

RestBackend _backend(http.Client client,
        {String url = _url,
        Duration timeout = const Duration(seconds: 5),
        int? maxResponseLength}) =>
    RestBackend(
        url: url,
        client: client,
        requestTimeout: timeout,
        maxResponseLength: maxResponseLength ?? 64 * 1024 * 1024);

Future<Object?> _error(Future<Object?> future) async {
  try {
    await future;
  } catch (e) {
    return e;
  }
  return null;
}

class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

class _AbortAwareClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  int aborted = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    var result = Completer<http.StreamedResponse>();
    var trigger = request is http.Abortable ? request.abortTrigger : null;
    trigger?.whenComplete(() {
      aborted++;
      result.completeError(http.RequestAbortedException(request.url));
    });
    return result.future;
  }
}

class _ThrowingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future.error(http.ClientException('boom', request.url));
}

void main() {
  group('normalizeUrl', () {
    test('accepts https, strips trailing slashes and spaces', () {
      expect(RestBackend.normalizeUrl(' https://a.test/ucdb/ '),
          'https://a.test/ucdb');
      expect(RestBackend.normalizeUrl('https://a.test//'), 'https://a.test');
      expect(RestBackend.normalizeUrl('https://a.test:8443/x/y'),
          'https://a.test:8443/x/y');
    });

    test('the result is canonical: scheme and host lower case, dot segments '
        'resolved, default port dropped, no trailing slash', () {
      var expected = 'https://example.com/ucdb';
      for (var input in [
        'HTTPS://Example.COM/ucdb',
        'https://example.com/ucdb/',
        'https://example.com/a/../ucdb',
        'https://example.com/./ucdb',
        'https://example.com:443/ucdb',
        'https://EXAMPLE.com/ucdb//',
      ]) {
        expect(RestBackend.normalizeUrl(input), expected, reason: input);
      }
      expect(RestBackend.normalizeUrl('https://example.com:8443/ucdb'),
          'https://example.com:8443/ucdb');
      expect(RestBackend.normalizeUrl('https://example.com/a/b/../../'),
          'https://example.com');
      expect(RestBackend.normalizeUrl('HTTP://LocalHost:80/x'),
          'http://localhost/x');
      expect(RestBackend.normalizeUrl('http://localhost:5001/x'),
          'http://localhost:5001/x');
      // Idempotent.
      var once = RestBackend.normalizeUrl('HTTPS://Example.com/a/../ucdb/');
      expect(RestBackend.normalizeUrl(once), once);
    });

    test('http only for localhost and 127.0.0.1', () {
      expect(RestBackend.normalizeUrl('http://localhost:5001/p/us/ucdb'),
          'http://localhost:5001/p/us/ucdb');
      expect(RestBackend.normalizeUrl('http://127.0.0.1:5001/ucdb'),
          'http://127.0.0.1:5001/ucdb');
      for (var bad in [
        'http://example.test/ucdb',
        'http://localhost.example.test/ucdb',
        'ftp://a.test/x',
        'a.test/ucdb',
      ]) {
        expect(() => RestBackend.normalizeUrl(bad),
            throwsA(isA<FormatException>()),
            reason: bad);
      }
    });

    test('rejects empty, query, fragment, credentials, blanks', () {
      for (var bad in [
        '',
        '   ',
        '/',
        'https://',
        'https://a.test/ucdb?x=1',
        'https://a.test/ucdb?',
        'https://a.test/ucdb#frag',
        'https://a.test/ucdb#',
        'https://user:pw@a.test/ucdb',
        'https://a.test/uc db',
      ]) {
        expect(() => RestBackend.normalizeUrl(bad),
            throwsA(isA<FormatException>()),
            reason: bad);
      }
    });

    test('the messages never contain the URL', () {
      for (var bad in [
        'http://example.test/SECRET-PATH',
        'https://a.test/SECRET-PATH?x=1',
        'https://u:p@a.test/SECRET-PATH',
        'https://a.test/SECRET-PATH#x',
      ]) {
        try {
          RestBackend.normalizeUrl(bad);
          fail('expected a FormatException for $bad');
        } on FormatException catch (e) {
          expect(e.message, isNot(contains('SECRET-PATH')));
          expect(e.message, isNot(contains('a.test')));
        }
      }
    });
  });

  group('request shape', () {
    test('GET <url>/<name>, no credentials, accepts raw bytes', () async {
      var server = FakeRestServer()..seed(_name, _bytes([1, 2, 3]));
      var backend = _backend(server.client, url: '$_url/');
      await backend.read(_name);
      var request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.url.toString(), '$_url/$_name');
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(request.headers['Accept'], 'application/octet-stream');
    });

    test('create: PUT with If-None-Match: * and the raw bytes', () async {
      var server = FakeRestServer();
      var backend = _backend(server.client);
      var version = await backend.write(_name, _bytes([9, 8, 7]));
      var request = server.requests.single;
      expect(request.method, 'PUT');
      expect(request.url.toString(), '$_url/$_name');
      expect(request.headers['If-None-Match'], '*');
      expect(request.headers.containsKey('If-Match'), isFalse);
      expect(request.headers['Content-Type'], 'application/octet-stream');
      expect(request.bodyBytes, [9, 8, 7]);
      expect(server.stored(_name), [9, 8, 7]);
      expect(version, server.generation(_name));
    });

    test('replace: PUT with a quoted If-Match, the version from the read',
        () async {
      var server = FakeRestServer()..seed(_name, _bytes([1]));
      var backend = _backend(server.client);
      var data = await backend.read(_name);
      var version = await backend.write(_name, _bytes([2, 2]),
          version: data.version);
      var put = server.requests.last;
      expect(put.headers['If-Match'], '"${data.version}"');
      expect(put.headers.containsKey('If-None-Match'), isFalse);
      expect(server.stored(_name), [2, 2]);
      expect(version, isNot(data.version));
      expect(version, server.generation(_name));
    });

    test('delete: DELETE with a quoted If-Match', () async {
      var server = FakeRestServer()..seed(_name, _bytes([1]));
      var backend = _backend(server.client);
      var data = await backend.read(_name);
      await backend.delete(_name, data.version!);
      var request = server.requests.last;
      expect(request.method, 'DELETE');
      expect(request.url.toString(), '$_url/$_name');
      expect(request.headers['If-Match'], '"${data.version}"');
      expect(server.stored(_name), isNull);
    });

    test('the name is encoded as one path segment', () async {
      var server = FakeRestServer();
      var backend = _backend(server.client);
      await backend.read('a b/c');
      expect(server.requests.single.url.toString(), '$_url/a%20b%2Fc');
    });
  });

  group('read', () {
    test('200: raw bytes and the ETag without quotes and W/', () async {
      var client = MockClient((_) async => http.Response.bytes([5, 6], 200,
          headers: {'ETag': 'W/"abc-1"'}));
      var data = await _backend(client).read(_name);
      expect(data.bytes, [5, 6]);
      expect(data.version, 'abc-1');
      expect(data.isEmpty, isFalse);
    });

    test('404: empty data, no version (the file is missing)', () async {
      var data = await _backend(FakeRestServer().client).read(_name);
      expect(data.isEmpty, isTrue);
      expect(data.version, isNull);
    });

    test('200 without an ETag is an error, not a file without version',
        () async {
      var server = FakeRestServer()
        ..seed(_name, _bytes([1]))
        ..sendEtag = false;
      var error = await _error(_backend(server.client).read(_name));
      expect(error, isA<RemoteBackendException>());
      expect((error as RemoteBackendException).statusCode, 200);
      expect(error.message, contains('ETag'));
      expect(error, isNot(isA<RemoteConflictException>()));
    });

    test('200 with an empty body is an error, not "missing"', () async {
      var client = MockClient(
          (_) async => http.Response('', 200, headers: {'etag': '"1"'}));
      var error = await _error(_backend(client).read(_name));
      expect(error, isA<RemoteBackendException>());
      expect((error as RemoteBackendException).statusCode, 200);
    });

    test('429 is a rate limit with Retry-After', () async {
      var client = MockClient(
          (_) async => http.Response('', 429, headers: {'Retry-After': '17'}));
      var error = await _error(_backend(client).read(_name));
      expect(error, isA<RemoteRateLimitException>());
      expect((error as RemoteRateLimitException).retryAfter,
          const Duration(seconds: 17));
      expect(error.statusCode, 429);
    });

    test('a 503 with Retry-After (server race on read) is a plain '
        'RemoteBackendException, not a rate limit', () async {
      var client = MockClient((_) async =>
          http.Response('', 503, headers: {'Retry-After': '1'}));
      var error = await _error(_backend(client).read(_name));
      expect(error, isA<RemoteBackendException>());
      expect(error, isNot(isA<RemoteRateLimitException>()));
      expect((error as RemoteBackendException).statusCode, 503);
      var writeError =
          await _error(_backend(client).write(_name, _bytes([1])));
      expect(writeError, isNot(isA<RemoteRateLimitException>()));
      expect((writeError as RemoteBackendException).statusCode, 503);
    });

    test('429 without a usable Retry-After has no retryAfter', () async {
      var client = MockClient((_) async =>
          http.Response('', 429, headers: {'Retry-After': 'Wed, 21 Oct'}));
      var error = await _error(_backend(client).read(_name));
      expect(error, isA<RemoteRateLimitException>());
      expect((error as RemoteRateLimitException).retryAfter, isNull);
    });

    test('every other status is a RemoteBackendException with the status; '
        '401/403 are not auth errors', () async {
      for (var status in [400, 401, 403, 405, 412, 428, 500, 502, 503]) {
        var client = MockClient((_) async => http.Response('x', status));
        var error = await _error(_backend(client).read(_name));
        expect(error, isA<RemoteBackendException>(), reason: '$status');
        expect(error, isNot(isA<RemoteAuthException>()), reason: '$status');
        expect(error, isNot(isA<RemoteConflictException>()),
            reason: '$status');
        expect((error as RemoteBackendException).statusCode, status);
        expect(error.message, contains('$status'));
      }
    });

    test('a transport error becomes a RemoteBackendException without the '
        'URL', () async {
      var error =
          await _error(_backend(_ThrowingClient(), url: '$_url/SECRET').read(_name));
      expect(error, isA<RemoteBackendException>());
      expect(error.toString(), isNot(contains('SECRET')));
      expect(error.toString(), isNot(contains('sync.example.test')));
      expect(error.toString(), contains('ClientException'));
    });

    test('an answer over the size cap is refused (Content-Length and while '
        'reading)', () async {
      var big = Uint8List(100);
      var client = MockClient((_) async =>
          http.Response.bytes(big, 200, headers: {'etag': '"1"'}));
      var error =
          await _error(_backend(client, maxResponseLength: 50).read(_name));
      expect(error, isA<RemoteBackendException>());
      expect(error.toString(), contains('more than'));

      // Ohne Content-Length (Streaming): beim Lesen.
      var streaming = MockClient.streaming((request, body) async =>
          http.StreamedResponse(
              Stream.fromIterable([Uint8List(30), Uint8List(30)]), 200,
              headers: {'etag': '"1"'}));
      error = await _error(
          _backend(streaming, maxResponseLength: 50).read(_name));
      expect(error, isA<RemoteBackendException>());
      expect(error.toString(), contains('more than'));

      var fine = await _backend(streaming, maxResponseLength: 60).read(_name);
      expect(fine.bytes.length, 60);
    });
  });

  group('write', () {
    test('201 and 200 return the new ETag', () async {
      for (var status in [200, 201]) {
        var client = MockClient((_) async =>
            http.Response('', status, headers: {'ETag': '"7"'}));
        expect(await _backend(client).write(_name, _bytes([1])), '7');
      }
    });

    test('412 is a conflict (exists already / other version / missing)',
        () async {
      var server = FakeRestServer()..seed(_name, _bytes([1]));
      var backend = _backend(server.client);
      // Anlegen, obwohl es sie gibt.
      var e1 = await _error(backend.write(_name, _bytes([2])));
      expect(e1, isA<RemoteConflictException>());
      expect((e1 as RemoteConflictException).statusCode, 412);
      // Veraltete Version.
      var e2 = await _error(backend.write(_name, _bytes([2]), version: '999'));
      expect(e2, isA<RemoteConflictException>());
      // Version einer fehlenden Datei.
      server.deleteFile(_name);
      var e3 = await _error(backend.write(_name, _bytes([2]), version: '1'));
      expect(e3, isA<RemoteConflictException>());
      // Nichts wurde geschrieben.
      expect(server.stored(_name), isNull);
    });

    test('429 is a rate limit', () async {
      var client = MockClient(
          (_) async => http.Response('', 429, headers: {'retry-after': '3'}));
      var error = await _error(_backend(client).write(_name, _bytes([1])));
      expect(error, isA<RemoteRateLimitException>());
      expect((error as RemoteRateLimitException).retryAfter,
          const Duration(seconds: 3));
    });

    test('other statuses (428, 413, 500, 401) are RemoteBackendExceptions',
        () async {
      for (var status in [400, 401, 403, 404, 413, 428, 500, 503]) {
        var client = MockClient((_) async => http.Response('', status));
        var error = await _error(_backend(client).write(_name, _bytes([1])));
        expect(error, isA<RemoteBackendException>(), reason: '$status');
        expect(error, isNot(isA<RemoteConflictException>()),
            reason: '$status');
        expect(error, isNot(isA<RemoteAuthException>()), reason: '$status');
        expect((error as RemoteBackendException).statusCode, status);
      }
    });

    test('a 2xx without an ETag is an error', () async {
      var server = FakeRestServer()..sendEtag = false;
      var error =
          await _error(_backend(server.client).write(_name, _bytes([1])));
      expect(error, isA<RemoteBackendException>());
      expect(error.toString(), contains('ETag'));
    });
  });

  group('delete', () {
    test('204 and 200 are fine', () async {
      for (var status in [200, 204]) {
        var client = MockClient((_) async => http.Response('', status));
        await _backend(client).delete(_name, '1');
      }
    });

    test('412 and 404 are conflicts', () async {
      for (var status in [404, 412]) {
        var client = MockClient((_) async => http.Response('', status));
        var error = await _error(_backend(client).delete(_name, '1'));
        expect(error, isA<RemoteConflictException>(), reason: '$status');
        expect((error as RemoteConflictException).statusCode, status);
      }
    });

    test('against the server: other version or missing file conflict',
        () async {
      var server = FakeRestServer()..seed(_name, _bytes([1]));
      var backend = _backend(server.client);
      expect(await _error(backend.delete(_name, '999')),
          isA<RemoteConflictException>());
      expect(server.stored(_name), isNotNull);
      server.deleteFile(_name);
      expect(await _error(backend.delete(_name, '1')),
          isA<RemoteConflictException>());
    });

    test('429 and other statuses', () async {
      var limited = MockClient((_) async => http.Response('', 429));
      expect(await _error(_backend(limited).delete(_name, '1')),
          isA<RemoteRateLimitException>());
      var broken = MockClient((_) async => http.Response('', 500));
      var error = await _error(_backend(broken).delete(_name, '1'));
      expect(error, isA<RemoteBackendException>());
      expect((error as RemoteBackendException).statusCode, 500);
    });
  });

  group('invalid URL', () {
    test('every call fails with a message that does not repeat the URL',
        () async {
      var server = FakeRestServer();
      var backend = _backend(server.client,
          url: 'http://example.test/SECRET-PATH');
      for (var call in [
        () => backend.read(_name),
        () => backend.write(_name, _bytes([1])),
        () => backend.delete(_name, '1'),
      ]) {
        var error = await _error(call());
        expect(error, isA<RemoteBackendException>());
        expect(error.toString(), isNot(contains('SECRET-PATH')));
      }
      expect(server.requests, isEmpty);
    });
  });

  group('timeout and abort', () {
    test('a request without answer is aborted and ends in a '
        'RemoteTimeoutException that names the sync server', () async {
      var client = _AbortAwareClient();
      var backend = _backend(client, timeout: const Duration(milliseconds: 30));
      var error = await _error(backend.read(_name));
      expect(error, isA<RemoteTimeoutException>());
      expect((error as RemoteTimeoutException).message,
          startsWith('Sync server did not respond within 30 ms'));
      expect(error.message, isNot(contains('GitHub')));
      await Future<void>.delayed(Duration.zero);
      expect(client.aborted, 1);
      expect(client.requests.single, isA<http.Abortable>());
    });

    test('write and delete are aborted too and then count as settled',
        () async {
      var client = _AbortAwareClient();
      var backend = _backend(client, timeout: const Duration(milliseconds: 30));
      var w = backend.write(_name, _bytes([1]));
      var pending = backend.whenWritesSettled();
      expect(await _error(w), isA<RemoteTimeoutException>());
      expect(await _error(backend.delete(_name, '1')),
          isA<RemoteTimeoutException>());
      await pending.timeout(const Duration(seconds: 1));
      await backend.whenWritesSettled().timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      expect(client.aborted, 2);
      expect(client.requests.map((r) => r.method), ['PUT', 'DELETE']);
    });

    test('a client that ignores the abort still ends in the timeout and '
        'counts as settled', () async {
      var backend =
          _backend(_HangingClient(), timeout: const Duration(milliseconds: 30));
      expect(await _error(backend.write(_name, _bytes([1]))),
          isA<RemoteTimeoutException>());
      await backend.whenWritesSettled().timeout(const Duration(seconds: 1));
    });

    test('headers that arrived but a body that never ends also time out',
        () async {
      var abortSeen = false;
      var client = MockClient.streaming((request, body) async {
        (request as http.Abortable).abortTrigger!.whenComplete(() {
          abortSeen = true;
        });
        return http.StreamedResponse(StreamController<List<int>>().stream, 200,
            headers: {'etag': '"1"'});
      });
      var backend = _backend(client, timeout: const Duration(milliseconds: 30));
      expect(await _error(backend.read(_name)), isA<RemoteTimeoutException>());
      await Future<void>.delayed(Duration.zero);
      expect(abortSeen, isTrue);
    });

    test('whenWritesSettled waits for a write that is under way', () async {
      var gate = Completer<void>();
      var client = MockClient((request) async {
        await gate.future;
        return http.Response('', 201, headers: {'etag': '"1"'});
      });
      var backend = _backend(client);
      var write = backend.write(_name, _bytes([1]));
      var settled = false;
      var waiting = backend.whenWritesSettled().then((_) => settled = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(settled, isFalse);
      gate.complete();
      await write;
      await waiting;
      expect(settled, isTrue);
    });
  });

  group('against the protocol server', () {
    test('create, read, replace, conflict on a stale version, delete',
        () async {
      var server = FakeRestServer();
      var a = _backend(server.client);
      var b = _backend(server.client);

      expect((await a.read(_name)).isEmpty, isTrue);
      var v1 = await a.write(_name, _bytes([1]));
      var seenByB = await b.read(_name);
      expect(seenByB.version, v1);
      var v2 = await a.write(_name, _bytes([2]), version: v1);
      // B hat noch v1: sein Schreiben scheitert, nichts geht verloren.
      expect(await _error(b.write(_name, _bytes([3]), version: seenByB.version)),
          isA<RemoteConflictException>());
      expect(server.stored(_name), [2]);
      await a.delete(_name, v2!);
      expect((await b.read(_name)).isEmpty, isTrue);
      // Ohne Version legt B die Datei wieder an (so kennt es nur configure).
      await b.write(_name, _bytes([4]));
      expect(server.stored(_name), [4]);
      // Zweites Anlegen scheitert.
      expect(await _error(a.write(_name, _bytes([5]))),
          isA<RemoteConflictException>());
    });

    test('displayName and id', () {
      var backend = _backend(FakeRestServer().client);
      expect(backend.displayName, 'Sync server');
      expect(backend.id, 'rest');
    });
  });
}
