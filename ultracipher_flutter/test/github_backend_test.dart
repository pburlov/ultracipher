// Tests for the GitHub-backed RemoteBackend (github_backend.dart).
//
// No network: every test injects a stub http.Client. A fake in this file
// (instead of package:http's MockClient) keeps the request assertions —
// path, auth header, sha plumbing — explicit and in one place.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ultracipher_flutter/src/backend/github_backend.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
import 'package:ultracipher_flutter/src/commons.dart' show describeError;

const _token = 'ghp_TESTTOKEN';
const _owner = 'someowner';
const _repo = 'ultracipher-data';

/// Minimal stub: handlers keyed by `"METHOD <path>"`, falling back to 404.
class _StubClient extends http.BaseClient {
  final Map<String, http.Response Function(http.BaseRequest)> handlers;
  final List<http.BaseRequest> requests = [];
  final List<String?> bodies = [];

  _StubClient(this.handlers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    String? body;
    if (request is http.Request) body = request.body;
    bodies.add(body);
    var key = '${request.method} ${request.url.path}';
    var handler = handlers[key];
    http.Response response;
    if (handler != null) {
      response = handler(request);
    } else {
      response = http.Response('not found', 404);
    }
    return http.StreamedResponse(
        Stream.value(Uint8List.fromList(response.bodyBytes)),
        response.statusCode,
        headers: response.headers);
  }
}

/// A client whose requests never answer.
class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

/// A client that never answers but honours `abortTrigger` like IOClient does
/// before the response arrives: it records the abort and fails the request
/// with [http.RequestAbortedException].
class _AbortAwareClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  int aborted = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    var result = Completer<http.StreamedResponse>();
    var trigger = request is http.Abortable ? request.abortTrigger : null;
    if (trigger != null) {
      trigger.whenComplete(() {
        aborted++;
        result.completeError(http.RequestAbortedException(request.url));
      });
    }
    return result.future;
  }
}

/// Answers 200 right away, but the body stream never ends (headers arrived,
/// then the connection stalls). It honours the abort like IOClient: the body
/// stream gets the error.
class _StalledBodyClient extends http.BaseClient {
  int aborted = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var body = StreamController<List<int>>();
    var trigger = request is http.Abortable ? request.abortTrigger : null;
    trigger?.whenComplete(() {
      aborted++;
      body
        ..addError(http.RequestAbortedException(request.url))
        ..close();
    });
    return http.StreamedResponse(body.stream, 200);
  }
}

/// Answers the first request with [first] and lets every later one hang (the
/// Contents answer arrives, the blob request stalls).
class _FirstThenHangingClient extends http.BaseClient {
  final http.Response first;
  final List<http.BaseRequest> requests = [];

  _FirstThenHangingClient(this.first);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (requests.length > 1) {
      return Completer<http.StreamedResponse>().future;
    }
    return http.StreamedResponse(
        Stream.value(Uint8List.fromList(first.bodyBytes)), first.statusCode,
        headers: first.headers);
  }
}

/// Answers every request once [response] completes.
class _GatedClient extends http.BaseClient {
  final Completer<http.StreamedResponse> response;

  _GatedClient(this.response);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      response.future;
}


http.Response _json(Object json, int status) => http.Response(
    jsonEncode(json), status,
    headers: {'content-type': 'application/json'});

/// The API `content` for a file holding [bytes] as base64 text: the file
/// content is `base64.encode(bytes)`, and the Contents API carries that
/// base64-encoded again.
String _apiContent(List<int> bytes) =>
    base64.encode(utf8.encode(base64.encode(bytes)));

GithubBackend _backend(_StubClient stub) => GithubBackend(
    owner: _owner, repo: _repo, token: _token, client: stub);

/// The three requests that go through the status mapping, by name, with
/// the HTTP method each one sends.
const _methods = {'read': 'GET', 'write': 'PUT', 'delete': 'DELETE'};

/// Calls the backend method [op] (see [_methods]) against a single canned
/// [response] and returns the exception it throws.
Future<Object> _failureOf(String op, http.Response response) {
  var stub = _StubClient({
    '${_methods[op]} /repos/$_owner/$_repo/contents/test.txt': (_) => response,
  });
  var backend = _backend(stub);
  Future<void> call() async {
    if (op == 'read') {
      await backend.read('test');
    } else if (op == 'write') {
      await backend.write('test', Uint8List(0), version: 'sha');
    } else {
      await backend.delete('test', 'sha');
    }
  }

  return captureException(call());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('read returns the decoded bytes and the blob sha as version', () async {
    var ciphertext = Uint8List.fromList([0, 1, 2, 3, 4, 5]);
    // Whitespace on both layers: the API wraps its base64 envelope every 60
    // characters, and the file text itself ends in a newline. The backend
    // must tolerate both.
    var envelope = base64.encode(utf8.encode('${base64.encode(ciphertext)}\n'))
        .replaceAllMapped(RegExp(r'.{1,60}'), (m) => '${m[0]}\n');
    var stub = _StubClient({
      'GET /repos/$_owner/$_repo/contents/test.txt': (_) => _json({
            'sha': 'abc123',
            'content': envelope,
            'encoding': 'base64',
          }, 200),
    });
    var backend = _backend(stub);

    var data = await backend.read('test');

    expect(data.bytes, equals(ciphertext));
    expect(data.version, equals('abc123'));
    expect(data.isEmpty, isFalse);
    // Auth travels in the header, never in the URL, and the file path
    // carries the user.
    var request = stub.requests.single;
    expect(request.url.path, contains('test.txt'));
    expect(request.headers['Authorization'], equals('Bearer $_token'));
    expect(request.url.queryParameters.values.join(),
        isNot(contains(_token)));
  });

  test('read of a missing file yields empty bytes and null version', () async {
    var stub = _StubClient({});
    var backend = _backend(stub);

    var data = await backend.read('newuser');

    expect(data.isEmpty, isTrue);
    expect(data.version, isNull);
  });

  test('read maps 401 to RemoteAuthException', () async {
    var stub = _StubClient({
      'GET /repos/$_owner/$_repo/contents/test.txt': (_) =>
          http.Response('bad credentials', 401),
    });

    await expectLater(_backend(stub).read('test'),
        throwsA(isA<RemoteAuthException>()));
  });

  test('read surfaces other statuses as RemoteBackendException with code',
      () async {
    var stub = _StubClient({
      'GET /repos/$_owner/$_repo/contents/test.txt': (_) =>
          http.Response('boom', 500),
    });

    var error = await captureException(_backend(stub).read('test'));
    expect(error, isA<RemoteBackendException>());
    expect((error as RemoteBackendException).statusCode, equals(500));
  });

  test('read failure never leaks the token in its message', () async {
    var stub = _StubClient({
      'GET /repos/$_owner/$_repo/contents/test.txt': (_) =>
          http.Response('boom', 500),
    });

    var error = await captureException(_backend(stub).read('test'));
    expect(error.toString(), isNot(contains(_token)));
  });

  test('write without version creates the file (no sha sent)', () async {
    Map? sent;
    var stub = _StubClient({
      'PUT /repos/$_owner/$_repo/contents/test.txt': (request) {
        sent = jsonDecode((request as http.Request).body);
        return _json({
          'content': {'sha': 'newsha1'}
        }, 201);
      },
    });

    var newVersion = await _backend(stub)
        .write('test', Uint8List.fromList([9, 8, 7]));

    expect(newVersion, equals('newsha1'));
    expect(sent!.containsKey('sha'), isFalse,
        reason: 'a create must not send a sha; the API rejects it with 422');
    expect(sent!['content'], equals(_apiContent([9, 8, 7])));
    expect(sent!['branch'], equals('main'));
  });

  test('write with version sends the sha and returns the new one', () async {
    Map? sent;
    var stub = _StubClient({
      'PUT /repos/$_owner/$_repo/contents/test.txt': (request) {
        sent = jsonDecode((request as http.Request).body);
        return _json({
          'content': {'sha': 'newsha2'}
        }, 200);
      },
    });

    var newVersion = await _backend(stub)
        .write('test', Uint8List.fromList([1]), version: 'oldsha');

    expect(sent!['sha'], equals('oldsha'));
    expect(newVersion, equals('newsha2'));
  });

  test('write maps 409 and 422 to RemoteConflictException', () async {
    for (var status in [409, 422]) {
      var stub = _StubClient({
        'PUT /repos/$_owner/$_repo/contents/test.txt': (_) =>
            http.Response('conflict', status),
      });

      var error = await captureException(
          _backend(stub).write('test', Uint8List(0), version: 'stale'));
      expect(error, isA<RemoteConflictException>(),
          reason: 'status $status should be a conflict, not a generic error');
      expect((error as RemoteConflictException).statusCode, equals(status));
    }
  });

  test('write maps 401 to RemoteAuthException', () async {
    var stub = _StubClient({
      'PUT /repos/$_owner/$_repo/contents/test.txt': (_) =>
          http.Response('bad credentials', 401),
    });

    await expectLater(
        _backend(stub).write('test', Uint8List(0)),
        throwsA(isA<RemoteAuthException>()));
  });

  test('read-then-write threads the version through (round trip)', () async {
    var stub = _StubClient({
      'GET /repos/$_owner/$_repo/contents/test.txt': (_) => _json({
            'sha': 'readsha',
            'content': _apiContent([5, 6]),
            'encoding': 'base64',
          }, 200),
      'PUT /repos/$_owner/$_repo/contents/test.txt': (request) {
        var sent = jsonDecode((request as http.Request).body);
        expect(sent['sha'], equals('readsha'));
        return _json({
          'content': {'sha': 'writesha'}
        }, 200);
      },
    });
    var backend = _backend(stub);

    var data = await backend.read('test');
    var newVersion = await backend.write('test', data.bytes,
        version: data.version);

    expect(newVersion, equals('writesha'));
  });

  test('pathForName escapes names that are unsafe in a path', () {
    expect(GithubBackend.pathForName('a/b c'), equals('a%2Fb%20c.txt'));
    expect(GithubBackend.pathForName('  test  '), equals('test.txt'));
  });

  test('a custom pathMapper decides the request path, not the name',
      () async {
    var stub = _StubClient({
      'GET /repos/$_owner/$_repo/contents/opaque.txt': (_) => _json({
            'sha': 's',
            'content': _apiContent([1]),
            'encoding': 'base64',
          }, 200),
    });
    var backend = GithubBackend(
        owner: _owner,
        repo: _repo,
        token: _token,
        pathMapper: (_) => 'opaque.txt',
        client: stub);

    var data = await backend.read('test');
    expect(data.bytes, equals(Uint8List.fromList([1])));
    expect(stub.requests.single.url.path, contains('opaque.txt'));
    expect(stub.requests.single.url.path, isNot(contains('test')));
  });

  test('the commit message is fixed and names no user', () async {
    Map? sent;
    var stub = _StubClient({
      'PUT /repos/$_owner/$_repo/contents/test.txt': (request) {
        sent = jsonDecode((request as http.Request).body);
        return _json({
          'content': {'sha': 's'}
        }, 201);
      },
    });

    await _backend(stub).write('test', Uint8List.fromList([1]));

    expect(sent!['message'], equals('Save database'));
  });

  test('written file is base64 text only, and reads back to the same bytes',
      () async {
    var bytes = Uint8List.fromList(List.generate(300, (i) => (i * 37) & 0xff));
    Map? sent;
    var stub = _StubClient({
      'PUT /repos/$_owner/$_repo/contents/test.txt': (request) {
        sent = jsonDecode((request as http.Request).body);
        return _json({
          'content': {'sha': 's1'}
        }, 201);
      },
    });

    await _backend(stub).write('test', bytes);

    // The envelope decodes to the file itself: one line of base64 characters.
    var fileText = utf8.decode(base64.decode(sent!['content'] as String));
    expect(fileText, matches(RegExp(r'^[A-Za-z0-9+/=]+$')));
    expect(fileText, equals(base64.encode(bytes)));

    // Reading the same envelope back yields the original bytes.
    var readStub = _StubClient({
      'GET /repos/$_owner/$_repo/contents/test.txt': (_) => _json({
            'sha': 's1',
            'content': sent!['content'],
            'encoding': 'base64',
          }, 200),
    });
    var data = await _backend(readStub).read('test');
    expect(data.bytes, equals(bytes));
  });

  test('a file that is not base64 text fails as a parse error, without its '
      'content', () async {
    for (var raw in [
      [0xff, 0xfe], // not UTF-8
      utf8.encode('secret-looking text!'), // UTF-8, but not base64
    ]) {
      var stub = _StubClient({
        'GET /repos/$_owner/$_repo/contents/test.txt': (_) => _json({
              'sha': 's',
              'content': base64.encode(raw),
              'encoding': 'base64',
            }, 200),
      });

      var error = await captureException(_backend(stub).read('test'));
      expect(error, isA<RemoteBackendException>());
      expect(error.toString(), contains('Failed to parse GitHub response'));
      expect(error.toString(), isNot(contains('secret')));
    }
  });

  test('an oversized file is refused before decoding, in either base64 layer, '
      'as a clean parse error', () async {
    GithubBackend small(_StubClient stub) => GithubBackend(
        owner: _owner,
        repo: _repo,
        token: _token,
        client: stub,
        maxTextLength: 100);
    _StubClient answering(String content) => _StubClient({
          'GET /repos/$_owner/$_repo/contents/test.txt': (_) => _json(
              {'sha': 's', 'content': content, 'encoding': 'base64'}, 200),
        });

    // Inner text just within the limit still reads.
    var ok = await small(answering(
            base64.encode(utf8.encode(base64.encode(List.filled(60, 1))))))
        .read('test');
    expect(ok.bytes, hasLength(60));

    for (var content in [
      // Inner text of 104 characters (> 100), validly encoded.
      base64.encode(utf8.encode(base64.encode(List.filled(78, 1)))),
      // Outer layer far above its limit (4 * 34 = 136 characters).
      'A' * 137,
      // Raw length above twice the limit, even though mostly whitespace.
      ' ' * 273,
    ]) {
      var error =
          await captureException(small(answering(content)).read('test'));
      expect(error, isA<RemoteBackendException>(), reason: '${content.length}');
      expect(error.toString(), contains('Failed to parse GitHub response'));
    }
  });

  test('resolveOwner returns the login for a valid token', () async {
    var stub = _StubClient({
      'GET /user': (request) {
        expect(request.headers['Authorization'], equals('Bearer $_token'));
        return _json({'login': _owner}, 200);
      },
    });

    expect(await GithubBackend.resolveOwner(_token, client: stub),
        equals(_owner));
  });

  test('resolveOwner maps 401 to RemoteAuthException', () async {
    var stub = _StubClient({'GET /user': (_) => http.Response('x', 401)});

    await expectLater(GithubBackend.resolveOwner('bad', client: stub),
        throwsA(isA<RemoteAuthException>()));
  });

  test('resolveOwner maps a rate limit to RemoteRateLimitException', () async {
    var stub = _StubClient({
      'GET /user': (_) => http.Response('', 429, headers: {'retry-after': '5'}),
    });

    var error = await captureException(
        GithubBackend.resolveOwner(_token, client: stub));
    expect(error, isA<RemoteRateLimitException>());
    expect((error as RemoteRateLimitException).retryAfter,
        equals(const Duration(seconds: 5)));
  });

  group('rate limits are not auth failures, for every request', () {
    for (var op in _methods.keys) {
      group(op, () {
        test('403 with x-ratelimit-remaining 0 is a rate limit', () async {
          var error = await _failureOf(
              op,
              http.Response('forbidden', 403,
                  headers: {'x-ratelimit-remaining': '0'}));

          expect(error, isA<RemoteRateLimitException>());
          expect(error, isNot(isA<RemoteAuthException>()));
          expect((error as RemoteBackendException).statusCode, equals(403));
          expect(error.toString(),
              equals('GitHub rate limit reached, try again later'));
        });

        test('403 whose body says API rate limit exceeded is a rate limit',
            () async {
          var error = await _failureOf(
              op, http.Response('API rate limit exceeded', 403));

          expect(error, isA<RemoteRateLimitException>());
          expect(error, isNot(isA<RemoteAuthException>()));
          expect((error as RemoteBackendException).statusCode, equals(403));
        });

        test('403 with retry-after 60 is a rate limit with retryAfter 60s',
            () async {
          var error = await _failureOf(
              op,
              http.Response('forbidden', 403,
                  headers: {'retry-after': '60'}));

          expect(error, isA<RemoteRateLimitException>());
          var rateLimit = error as RemoteRateLimitException;
          expect(rateLimit.retryAfter, equals(const Duration(seconds: 60)));
          expect(rateLimit.statusCode, equals(403));
        });

        test('429 is a rate limit, without retryAfter when none was sent',
            () async {
          var error = await _failureOf(op, http.Response('slow down', 429));

          expect(error, isA<RemoteRateLimitException>());
          var rateLimit = error as RemoteRateLimitException;
          expect(rateLimit.statusCode, equals(429));
          expect(rateLimit.retryAfter, isNull);
        });

        test('429 with retry-after is a rate limit with retryAfter', () async {
          var error = await _failureOf(op,
              http.Response('slow down', 429, headers: {'retry-after': '30'}));

          expect(error, isA<RemoteRateLimitException>());
          expect((error as RemoteRateLimitException).retryAfter,
              equals(const Duration(seconds: 30)));
        });

        test('403 without a rate-limit mark stays RemoteAuthException',
            () async {
          var error = await _failureOf(
              op,
              http.Response('{"message":"Resource not accessible"}', 403,
                  headers: {'x-ratelimit-remaining': '4999'}));

          expect(error, isA<RemoteAuthException>());
          expect(error, isNot(isA<RemoteRateLimitException>()));
          expect((error as RemoteBackendException).statusCode, equals(403));
        });

        test('plain 403 stays RemoteAuthException', () async {
          var error = await _failureOf(op, http.Response('forbidden', 403));

          expect(error, isA<RemoteAuthException>());
          expect(error, isNot(isA<RemoteRateLimitException>()));
        });

        test('401 stays RemoteAuthException', () async {
          var error =
              await _failureOf(op, http.Response('bad credentials', 401));

          expect(error, isA<RemoteAuthException>());
          expect(error, isNot(isA<RemoteRateLimitException>()));
        });

        test('rate-limit message never contains the token', () async {
          var error = await _failureOf(op, http.Response('slow down', 429));

          expect(error.toString(), isNot(contains(_token)));
        });
      });
    }
  });

  // Vor 'a hanging connection': dessen Aufrufe enden nie und bleiben sonst in
  // der prozessweiten Liste offener Schreibaufrufe.
  group('whenWritesSettled (plan R3)', () {
    GithubBackend backendFor(http.Client client) => GithubBackend(
        owner: _owner,
        repo: _repo,
        token: _token,
        client: client,
        requestTimeout: const Duration(milliseconds: 20));

    test('a write counts while its request is under way, across instances; '
        'reads do not count', () async {
      var response = Completer<http.StreamedResponse>();
      var backend = GithubBackend(
          owner: _owner,
          repo: _repo,
          token: _token,
          client: _GatedClient(response));

      var write = backend.write('u', Uint8List.fromList([1]));
      var settled = false;
      // Ein anderes Objekt: die Liste gilt fuer den ganzen Prozess.
      var waiting = GithubBackend(owner: _owner, repo: _repo, token: _token)
          .whenWritesSettled()
          .then((_) => settled = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(settled, isFalse);

      response.complete(http.StreamedResponse(const Stream.empty(), 500));
      await captureException(write);
      await waiting;
      expect(settled, isTrue);

      var read = GithubBackend(
              owner: _owner,
              repo: _repo,
              token: _token,
              client: _GatedClient(Completer()))
          .read('u');
      await GithubBackend(owner: _owner, repo: _repo, token: _token)
          .whenWritesSettled();
      read.then<void>((_) {}, onError: (Object _) {});
    });

    // Vorher (Timeout gibt nur beim Aufrufer auf, die Anfrage laeuft
    // weiter) blieb der Schreibaufruf offen, bis die Anfrage endete: ein
    // haengender Aufruf blockierte jeden Passwortwechsel. Jetzt bricht der
    // Timeout die Anfrage ab, und ein abgebrochener Aufruf gilt als erledigt.
    for (var op in ['write', 'delete']) {
      test('a $op the timeout aborted counts as settled', () async {
        var client = _AbortAwareClient();
        var backend = backendFor(client);

        var error = await captureException(op == 'write'
            ? backend.write('u', Uint8List.fromList([1]))
            : backend.delete('u', 'sha'));

        expect(error, isA<RemoteTimeoutException>());
        await Future<void>.delayed(Duration.zero); // abort callback runs
        expect(client.aborted, 1);
        await backend.whenWritesSettled().timeout(const Duration(seconds: 1));
      });

      test('a $op the timeout aborted counts as settled even for a client '
          'that ignores the abort', () async {
        var backend = backendFor(_HangingClient());

        var error = await captureException(op == 'write'
            ? backend.write('u', Uint8List.fromList([1]))
            : backend.delete('u', 'sha'));

        expect(error, isA<RemoteTimeoutException>());
        await backend.whenWritesSettled().timeout(const Duration(seconds: 1));
      });
    }
  });

  group('a stalled response body', () {
    GithubBackend stalled(http.Client client) => GithubBackend(
        owner: _owner,
        repo: _repo,
        token: _token,
        client: client,
        requestTimeout: const Duration(milliseconds: 50));

    test('is covered by the timeout: RemoteTimeoutException, request aborted, '
        'write settled', () async {
      var client = _StalledBodyClient();
      var backend = stalled(client);

      expect(await captureException(backend.read('u')),
          isA<RemoteTimeoutException>());
      expect(await captureException(backend.write('u', Uint8List.fromList([1]))),
          isA<RemoteTimeoutException>());
      expect(await captureException(backend.delete('u', 'sha')),
          isA<RemoteTimeoutException>());
      await Future<void>.delayed(Duration.zero);
      expect(client.aborted, 3);
      await backend.whenWritesSettled().timeout(const Duration(seconds: 1));
    });
  });

  group('files over 1 MB (Contents API without inline content)', () {
    const contentsKey = 'GET /repos/$_owner/$_repo/contents/test.txt';
    const blobKey = 'GET /repos/$_owner/$_repo/git/blobs/bigsha';

    /// What the Contents API answers for a large file.
    http.Response contentsNone({Object? sha = 'bigsha', Object? size = 100}) =>
        _json({
          if (sha != null) 'sha': sha,
          'size': size,
          'content': '',
          'encoding': 'none',
        }, 200);

    /// What the blob API answers: the same envelope, wrapped every 60 chars.
    http.Response blob(List<int> bytes) => _json({
          'sha': 'bigsha',
          'size': 100,
          'encoding': 'base64',
          'content': _apiContent(bytes)
              .replaceAllMapped(RegExp(r'.{1,60}'), (m) => '${m[0]}\n'),
        }, 200);

    test('the content comes from the blob API, the version stays the sha',
        () async {
      var bytes = Uint8List.fromList(List.generate(200, (i) => i));
      var stub = _StubClient({
        contentsKey: (_) => contentsNone(),
        blobKey: (_) => blob(bytes),
      });

      var data = await _backend(stub).read('test');

      expect(data.bytes, equals(bytes));
      expect(data.version, equals('bigsha'));
      expect(data.isEmpty, isFalse);
      expect(stub.requests, hasLength(2));
      var blobRequest = stub.requests.last;
      expect(blobRequest.method, 'GET');
      expect(blobRequest.url.toString(),
          '${GithubBackend.apiBase}/repos/$_owner/$_repo/git/blobs/bigsha');
      expect(blobRequest.headers['Authorization'], equals('Bearer $_token'));
      expect(blobRequest.headers['Accept'], 'application/vnd.github+json');
      expect(blobRequest.headers['X-GitHub-Api-Version'], isNotEmpty);
      expect(blobRequest is http.Abortable, isTrue);
    });

    test('a small file takes exactly one request, no blob call', () async {
      var stub = _StubClient({
        contentsKey: (_) => _json({
              'sha': 'smallsha',
              'size': 8,
              'content': _apiContent([1, 2, 3]),
              'encoding': 'base64',
            }, 200),
      });

      var data = await _backend(stub).read('test');

      expect(data.bytes, equals(Uint8List.fromList([1, 2, 3])));
      expect(stub.requests, hasLength(1));
    });

    test('a really empty file (size 0) is still empty bytes with its sha, '
        'without a blob call', () async {
      for (var encoding in ['base64', 'none']) {
        var stub = _StubClient({
          contentsKey: (_) => _json({
                'sha': 'emptysha',
                'size': 0,
                'content': '',
                'encoding': encoding,
              }, 200),
        });

        var data = await _backend(stub).read('test');

        expect(data.bytes, isEmpty, reason: encoding);
        expect(data.version, 'emptysha', reason: encoding);
        expect(stub.requests, hasLength(1), reason: encoding);
      }
    });

    test('a 200 with empty content but a size is never empty bytes',
        () async {
      // No `encoding: none` either: empty content with size > 0 is not
      // "empty", the content just was not delivered.
      var stub = _StubClient({
        contentsKey: (_) => _json(
            {'sha': 'bigsha', 'size': 100, 'content': '', 'encoding': 'base64'},
            200),
        blobKey: (_) => blob([7, 7]),
      });

      var data = await _backend(stub).read('test');

      expect(data.bytes, equals(Uint8List.fromList([7, 7])));
      expect(stub.requests, hasLength(2));
    });

    test('a size above the cap is refused without a blob request', () async {
      var stub = _StubClient({
        contentsKey: (_) => contentsNone(size: 101),
        blobKey: (_) => blob([1]),
      });
      var backend = GithubBackend(
          owner: _owner,
          repo: _repo,
          token: _token,
          client: stub,
          maxTextLength: 100);

      var error = await captureException(backend.read('test'));

      expect(error, isA<RemoteBackendException>());
      expect(error.toString(), contains('Failed to parse GitHub response'));
      expect(stub.requests, hasLength(1));
    });

    test('a size exactly at the cap is fetched', () async {
      var stub = _StubClient({
        contentsKey: (_) => contentsNone(size: 100),
        blobKey: (_) => blob(List.filled(60, 1)),
      });
      var backend = GithubBackend(
          owner: _owner,
          repo: _repo,
          token: _token,
          client: stub,
          maxTextLength: 100);

      expect((await backend.read('test')).bytes, hasLength(60));
    });

    test('blob content above the cap is refused although size said it fits',
        () async {
      var stub = _StubClient({
        contentsKey: (_) => contentsNone(size: 50),
        blobKey: (_) => blob(List.filled(78, 1)), // inner text: 104 > 100
      });
      var backend = GithubBackend(
          owner: _owner,
          repo: _repo,
          token: _token,
          client: stub,
          maxTextLength: 100);

      var error = await captureException(backend.read('test'));

      expect(error, isA<RemoteBackendException>());
      expect(error.toString(), contains('Failed to parse GitHub response'));
    });

    test('a blob 404 is an error, not an empty file', () async {
      var stub = _StubClient({
        contentsKey: (_) => contentsNone(),
        blobKey: (_) => http.Response('not found', 404),
      });

      var error = await captureException(_backend(stub).read('test'));

      expect(error, isA<RemoteBackendException>());
      expect(error, isNot(isA<RemoteAuthException>()));
      expect((error as RemoteBackendException).statusCode, 404);
      expect(error.toString(), isNot(contains(_token)));
    });

    test('a blob 401 is a RemoteAuthException', () async {
      var stub = _StubClient({
        contentsKey: (_) => contentsNone(),
        blobKey: (_) => http.Response('bad credentials', 401),
      });

      await expectLater(_backend(stub).read('test'),
          throwsA(isA<RemoteAuthException>()));
    });

    test('a blob rate limit is a RemoteRateLimitException, not an auth error',
        () async {
      for (var response in [
        http.Response('', 429, headers: {'retry-after': '7'}),
        http.Response('', 403, headers: {'x-ratelimit-remaining': '0'}),
      ]) {
        var stub = _StubClient({
          contentsKey: (_) => contentsNone(),
          blobKey: (_) => response,
        });

        var error = await captureException(_backend(stub).read('test'));

        expect(error, isA<RemoteRateLimitException>(),
            reason: '${response.statusCode}');
      }
    });

    test('another blob failure keeps its status code', () async {
      var stub = _StubClient({
        contentsKey: (_) => contentsNone(),
        blobKey: (_) => http.Response('boom', 500),
      });

      var error = await captureException(_backend(stub).read('test'));

      expect(error, isA<RemoteBackendException>());
      expect((error as RemoteBackendException).statusCode, 500);
    });

    test('a blob answer that is no base64 blob is a parse error', () async {
      for (var answer in [
        _json({'content': _apiContent([1]), 'encoding': 'utf-8'}, 200),
        _json({'encoding': 'base64'}, 200),
        http.Response('not json', 200),
      ]) {
        var stub = _StubClient({
          contentsKey: (_) => contentsNone(),
          blobKey: (_) => answer,
        });

        var error = await captureException(_backend(stub).read('test'));

        expect(error, isA<RemoteBackendException>());
        expect(error.toString(), contains('Failed to parse GitHub response'));
      }
    });

    test('a blob request without answer ends in a RemoteTimeoutException',
        () async {
      var client = _FirstThenHangingClient(contentsNone());
      var backend = GithubBackend(
          owner: _owner,
          repo: _repo,
          token: _token,
          client: client,
          requestTimeout: const Duration(milliseconds: 50));

      await expectLater(
          backend.read('test'), throwsA(isA<RemoteTimeoutException>()));
      expect(client.requests, hasLength(2));
    });

    test('encoding none without a sha is refused, no blob request', () async {
      var stub = _StubClient({
        contentsKey: (_) => contentsNone(sha: null),
        blobKey: (_) => blob([1]),
      });

      var error = await captureException(_backend(stub).read('test'));

      expect(error, isA<RemoteBackendException>());
      expect(error.toString(), contains('Failed to parse GitHub response'));
      expect(stub.requests, hasLength(1));
    });

    test('encoding none without a size is refused, no blob request',
        () async {
      var stub = _StubClient({
        contentsKey: (_) => _json(
            {'sha': 'bigsha', 'content': '', 'encoding': 'none'}, 200),
        blobKey: (_) => blob([1]),
      });

      var error = await captureException(_backend(stub).read('test'));

      expect(error, isA<RemoteBackendException>());
      expect(stub.requests, hasLength(1));
    });

    test('an unexpected encoding is refused, no blob request', () async {
      var stub = _StubClient({
        contentsKey: (_) => _json({
              'sha': 'bigsha',
              'size': 10,
              'content': _apiContent([1]),
              'encoding': 'utf-8',
            }, 200),
        blobKey: (_) => blob([1]),
      });

      var error = await captureException(_backend(stub).read('test'));

      expect(error, isA<RemoteBackendException>());
      expect(stub.requests, hasLength(1));
    });

    test('a file whose text is empty but whose size is not never reads as '
        'empty', () async {
      var stub = _StubClient({
        contentsKey: (_) => _json({
              'sha': 'bigsha',
              'size': 3,
              'content': base64.encode(utf8.encode('\n\n\n')),
              'encoding': 'base64',
            }, 200),
      });

      var error = await captureException(_backend(stub).read('test'));

      expect(error, isA<RemoteBackendException>());
    });
  });

  group('a hanging connection', () {
    GithubBackend hanging() => GithubBackend(
        owner: _owner,
        repo: _repo,
        token: _token,
        client: _HangingClient(),
        requestTimeout: const Duration(milliseconds: 50));

    test('read, write and delete fail with a RemoteTimeoutException with a '
        'clear message that names no secret', () async {
      var backend = hanging();
      Future<void> expectTimeout(Future<Object?> call) async {
        try {
          await call;
          fail('expected a RemoteTimeoutException');
        } on RemoteTimeoutException catch (e) {
          expect(e.message, 'GitHub did not respond within 50 ms. '
              'Check the network and try again.');
          expect(e.message, isNot(contains(_token)));
          expect(e.message, isNot(contains(_owner)));
          expect(describeError(e), e.message);
        }
      }

      await expectTimeout(backend.read('u'));
      await expectTimeout(backend.write('u', Uint8List.fromList([1, 2, 3])));
      await expectTimeout(backend.delete('u', 'sha'));
      await expectTimeout(GithubBackend.resolveOwner(_token,
          client: _HangingClient(),
          requestTimeout: const Duration(milliseconds: 50)));
    });

    test('the message names the timeout in seconds when it is a whole number',
        () {
      expect(RemoteTimeoutException(GithubBackend.defaultRequestTimeout).message,
          'GitHub did not respond within 30 s. Check the network and try '
          'again.');
    });

    test('every request type is aborted at the timeout, via AbortableRequest',
        () async {
      var client = _AbortAwareClient();
      var backend = GithubBackend(
          owner: _owner,
          repo: _repo,
          token: _token,
          client: client,
          requestTimeout: const Duration(milliseconds: 30));

      await captureException(backend.read('u'));
      await captureException(backend.write('u', Uint8List.fromList([1])));
      await captureException(backend.delete('u', 'sha'));
      await captureException(GithubBackend.resolveOwner(_token,
          client: client, requestTimeout: const Duration(milliseconds: 30)));

      expect(client.requests.map((r) => r.method),
          ['GET', 'PUT', 'DELETE', 'GET']);
      expect(client.requests.every((r) => r is http.Abortable), isTrue);
      await Future<void>.delayed(Duration.zero); // abort callbacks run
      expect(client.aborted, 4);
    });

    test('a request that answers in time is not aborted', () async {
      var stub = _StubClient({
        'GET /repos/$_owner/$_repo/contents/u.txt': (_) =>
            http.Response('', 404),
      });
      var backend = GithubBackend(
          owner: _owner,
          repo: _repo,
          token: _token,
          client: stub,
          requestTimeout: const Duration(seconds: 5));

      await backend.read('u');

      var trigger = (stub.requests.single as http.Abortable).abortTrigger!;
      var fired = false;
      trigger.whenComplete(() => fired = true);
      await Future<void>.delayed(Duration.zero);
      expect(fired, isFalse);
    });

    test('the default timeout is 30 seconds', () {
      expect(GithubBackend.defaultRequestTimeout, const Duration(seconds: 30));
    });
  });

}

/// Runs [future] and returns the thrown error (failing if none is thrown).
Future<Object> captureException(Future future) async {
  try {
    await future;
  } catch (e) {
    return e;
  }
  return fail('expected an exception, but none was thrown');
}
