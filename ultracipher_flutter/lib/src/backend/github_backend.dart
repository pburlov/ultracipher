import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../db_codec.dart' show maxBase64Length;
import '../sync_log.dart';
import 'remote_backend.dart';

/// GitHub-backed [RemoteBackend], using the repository Contents API.
///
/// Each database maps to one file in one repository, named after the
/// database (`<name>.txt`, see [pathForName]; the name is derived from the
/// key, so no cleartext leaves the device). The file holds the ciphertext as
/// one line of base64 text: exactly
/// `base64.encode(UltracipherApp.encryptDatabase(...))`, the same text the
/// app's "Export encrypted" produces, so a file can be imported as is. The
/// Contents API transports the file content base64-encoded as well, so the
/// bytes are base64-encoded twice on the wire and decoded twice on read
/// ([read], [write]). The commit message is fixed, the token travels in the
/// header.
///
/// The opaque [RemoteData.version] token is the blob `sha` the Contents API
/// returns on read and requires on update, which is exactly the optimistic
/// concurrency plumbing of the sync in `core.dart`: it writes back with the
/// version it just read, so a stale write fails with [RemoteConflictException] (HTTP 409/422) instead of
/// silently overwriting a newer database.
///
/// Authentication is a personal access token supplied by the caller (from the
/// database's `settings.github`). This class never touches
/// `SharedPreferences` or the database key itself, so there is no second
/// copy of the token-handling rules.
///
/// Files over 1 MB: the Contents API then answers with an empty `content` and
/// `encoding: "none"`; [read] fetches such a file through the Git blob API (a
/// second request, only in that case, and only below the size cap).
///
/// Error mapping:
/// - 401/403 become [RemoteAuthException]: the sync reports `authRequired`
///   and the user re-enters the token in "GitHub settings".
/// - Rate limits (429, or a 403 with a rate-limit mark, see
///   `_throwIfRateLimited`) become [RemoteRateLimitException], checked before
///   the auth mapping, so a healthy token is never reported as rejected.
/// - 409/422 on write become [RemoteConflictException]: the version `sha`
///   was missing or outdated.
/// - a request without answer within [requestTimeout] is aborted and becomes
///   [RemoteTimeoutException] (message for the user, see there).
/// - every other failure becomes [RemoteBackendException] with the
///   `statusCode` preserved. Messages never contain the token: auth travels
///   in the `Authorization` header, so it cannot leak through a logged URI
///   anyway, and messages stay collapsed
///   to type + status for the same reason.
class GithubBackend implements RemoteBackend {
  static const String apiBase = 'https://api.github.com';

  /// Repository used when the caller passes no explicit `repo`. It must
  /// already exist under [owner] (created on github.com) — the Contents
  /// API reads/writes files, it never creates repositories, so pointing at
  /// a missing repo surfaces as a 404 `RemoteBackendException` on write.
  static const String defaultRepo = 'ultracipher-data';

  /// Default for [requestTimeout].
  static const Duration defaultRequestTimeout = Duration(seconds: 30);

  /// Schreib- und Löschaufrufe (PUT/DELETE), die noch unterwegs sind.
  /// Prozessweit, nicht je Instanz: ein abgebrochener Sync einer früheren
  /// Sitzung schreibt über ein anderes Objekt an dieselbe Datei.
  ///
  /// Ein Aufruf zählt als erledigt, sobald seine Anfrage endet oder der
  /// Timeout sie abgebrochen hat ([_send]). Restrisiko, und der übliche Fall
  /// eines Timeouts: der Body ist schon gesendet, und GitHub verarbeitet den
  /// PUT nach dem Abbruch trotzdem noch. Mögliche Folge: eine wiederangelegte
  /// verwaiste Datei unter dem alten Namen, kein Datenverlust; die
  /// sha-Prüfung des späteren Löschens bzw. Schreibens lässt veraltete
  /// Aufrufe scheitern, statt etwas zu überschreiben. Ein Client, der den
  /// `abortTrigger` ignoriert, läuft nach dem Timeout weiter, gilt durch den
  /// Sicherheitsnetz-Timeout aber trotzdem schon als erledigt.
  static final Set<Future<void>> _pendingWrites = {};

  /// Sendet eine Anfrage als [http.AbortableRequest]. Nach [timeout] wird sie
  /// wirklich abgebrochen (`abortTrigger`: IOClient bricht die Verbindung ab,
  /// BrowserClient ruft `AbortController.abort()` auf) und der Aufruf wirft
  /// [RemoteTimeoutException]. Der zusätzliche `Future.timeout` ist das
  /// Sicherheitsnetz für einen Client, der den Abbruch nicht beachtet.
  /// [track] trägt PUT/DELETE in [_pendingWrites] ein.
  static Future<http.Response> _send(
    http.Client client,
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String? body,
    required Duration timeout,
    bool track = false,
    _Trace? trace,
  }) {
    var abort = Completer<void>();
    var request = http.AbortableRequest(method, uri,
        abortTrigger: abort.future)
      ..headers.addAll(headers);
    if (body != null) request.body = body;

    var settled = Completer<void>();
    void finish() {
      if (!settled.isCompleted) settled.complete();
      _pendingWrites.remove(settled.future);
    }

    if (track) _pendingWrites.add(settled.future);
    var call = (() async =>
        http.Response.fromStream(await client.send(request)))();
    if (track) {
      call.then<void>((_) => finish(), onError: (Object _) => finish());
    }
    // Nur mithören (Sync-Log): das zurückgegebene Future und seine Fehler
    // bleiben unverändert. Nach einem Timeout gibt es genau einen Eintrag
    // (`timeout`): weder der Abbruch des Clients noch eine späte Antwort
    // eines Clients, der den Abbruch ignoriert, erzeugt einen zweiten.
    var timedOut = false;
    if (trace != null) {
      call.then<void>((response) {
        if (!timedOut) trace.response(method, response);
      }, onError: (Object e) {
        if (!timedOut) trace.failure(method, e);
      });
    }
    return call.timeout(timeout, onTimeout: () {
      timedOut = true;
      trace?.timeout(method, timeout);
      if (!abort.isCompleted) abort.complete();
      finish();
      throw RemoteTimeoutException(timeout, 'GitHub');
    });
  }

  @override
  Future<void> whenWritesSettled() async {
    while (_pendingWrites.isNotEmpty) {
      await Future.wait(_pendingWrites.toList());
    }
  }

  /// Upper bound for one HTTP call of [read]/[write]/[delete] (and
  /// [resolveOwner]). A hanging connection must not block the sync (one run
  /// at a time) forever; at the timeout the request is aborted and the call
  /// fails with a [RemoteTimeoutException].
  final Duration requestTimeout;

  /// Upper bound for the inner base64 text of a file read by [read] (the text
  /// of `base64.encode(bytes)`); the Contents API envelope around it is capped
  /// to its base64 size plus line breaks. Both caps are checked BEFORE
  /// decoding. Default: the app's [maxBase64Length]; lowered only by tests.
  final int maxTextLength;

  final String owner;
  final String repo;
  final String token;
  /// Branch der Datei. Leer = Standard-Branch des Repositorys (egal ob
  /// `main` oder `master`): dann gehen weder `ref` noch `branch` an die API.
  final String branch;
  final http.Client _client;

  /// Sync-Log (nur im Speicher); `null` loggt nichts. Siehe [_Trace].
  final SyncLog? log;

  /// Maps a database name to its file path. Defaults to [pathForName]
  /// (production uses the default); a test seam.
  final String Function(String name) _pathMapper;

  GithubBackend({
    required this.owner,
    required this.repo,
    required this.token,
    this.branch = '',
    String Function(String name)? pathMapper,
    http.Client? client,
    this.requestTimeout = defaultRequestTimeout,
    this.maxTextLength = maxBase64Length,
    this.log,
  })  : _pathMapper = pathMapper ?? pathForName,
        _client = client ?? http.Client();

  @override
  String get id => 'github';

  @override
  String get displayName => 'GitHub';

  /// File path inside the repository holding the database called [name].
  ///
  /// `Uri.encodeComponent` keeps slashes, spaces and non-ASCII out of the
  /// path (a database name is base64url and needs no escaping); the `.txt`
  /// suffix marks the file as the base64 text described on the class.
  static String pathForName(String name) =>
      '${Uri.encodeComponent(name.trim())}.txt';

  /// The path [name] resolves to under this instance's [_pathMapper].
  String pathFor(String name) => _pathMapper(name);

  /// Log-Kontext einer Anfrage zur Datenbank [name] (null ohne Log).
  _Trace? _trace(String operation, String endpoint, String? name,
      {int? epoch}) {
    var log = this.log;
    if (log == null) return null;
    return _Trace(log, operation, endpoint,
        owner: owner,
        repo: repo,
        branch: branch,
        name: name,
        pathSuffix: name == null ? null : _suffix(pathFor(name)),
        token: token,
        epoch: epoch);
  }

  Uri _contentUri(String name) => Uri.parse(
      '$apiBase/repos/$owner/$repo/contents/${pathFor(name)}'
      '${branch.isEmpty ? '' : '?ref=${Uri.encodeComponent(branch)}'}');

  Uri _writeUri(String name) => Uri.parse(
      '$apiBase/repos/$owner/$repo/contents/${pathFor(name)}');

  Map<String, String> get _headers => {
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  /// A 404 (no file yet, or nothing stored under this name) is not an
  /// error: it yields empty bytes with a `null` version; the caller decides
  /// what a missing file means.
  ///
  /// Files over 1 MB come back from the Contents API as 200 with
  /// `encoding: "none"` and an empty `content` (but `sha` and `size`). Then
  /// and only then a second request fetches the content through the Git blob
  /// API, after the size cap; the version stays the `sha` of the first answer
  /// (it is the blob's sha). A 200 never yields empty bytes unless the file
  /// really is empty (`size == 0`): the caller would take that for a missing
  /// file and overwrite the real one.
  @override
  Future<RemoteData> read(String name) async {
    var trace = _trace('read file', 'contents', name);
    var response = await _get(_contentUri(name), trace: trace);
    if (response.statusCode == 200) {
      String sha;
      String? envelope;
      int? size;
      try {
        var json = jsonDecode(response.body) as Map<String, dynamic>;
        sha = json['sha'] as String;
        size = json['size'] as int?;
        var encoding = json['encoding'] as String?;
        var content = json['content'] as String?;
        if (size == 0) {
          envelope = content ?? '';
        } else if (encoding == 'none' ||
            (size != null && size > 0 && (content ?? '').isEmpty)) {
          // Content not delivered inline: check the cap before fetching.
          if (size == null || size > maxTextLength) {
            throw const FormatException('File is too large');
          }
        } else if (encoding == 'base64' && content != null) {
          envelope = content;
        } else {
          throw const FormatException('Unexpected response');
        }
      } catch (e) {
        trace?.parseError(response.statusCode);
        throw RemoteBackendException(
            'Failed to parse GitHub response (${e.runtimeType})',
            statusCode: response.statusCode);
      }
      envelope ??= await _readBlob(sha, name, trace?._epoch);
      try {
        var ciphertext = _decodeEnvelope(envelope);
        if (ciphertext.isEmpty && size != 0) {
          throw const FormatException('Unexpected empty file');
        }
        return RemoteData(bytes: ciphertext, version: sha);
      } catch (e) {
        trace?.parseError(response.statusCode);
        throw RemoteBackendException(
            'Failed to parse GitHub response (${e.runtimeType})',
            statusCode: response.statusCode);
      }
    }
    if (response.statusCode == 404) {
      return RemoteData(bytes: Uint8List(0), version: null);
    }
    _throwForStatus(response);
  }

  /// GET with the shared transport-error mapping of [read].
  Future<http.Response> _get(Uri uri, {_Trace? trace}) async {
    try {
      return await _send(_client, 'GET', uri,
          headers: _headers, timeout: requestTimeout, trace: trace);
    } on RemoteTimeoutException {
      rethrow;
    } catch (e) {
      throw RemoteBackendException(
          'Failed to read data from GitHub (${e.runtimeType})');
    }
  }

  /// Fetches the content of the blob [sha] (Git blob API) as the base64
  /// envelope the Contents API would have delivered inline. Unlike the
  /// Contents request, a 404 is no "missing file" here: the sha was just
  /// returned, so the file exists and the answer is an error.
  Future<String> _readBlob(String sha, String name, int? epoch) async {
    // Die Epoche des Datei-Trace: ein Sitzungswechsel dazwischen verwirft
    // auch den Blob-Eintrag.
    var trace = _trace('read blob', 'git/blobs', name, epoch: epoch);
    var response = await _get(
        Uri.parse(
            '$apiBase/repos/$owner/$repo/git/blobs/${Uri.encodeComponent(sha)}'),
        trace: trace);
    if (response.statusCode == 200) {
      try {
        var json = jsonDecode(response.body) as Map<String, dynamic>;
        if (json['encoding'] != 'base64') {
          throw const FormatException('Unexpected response');
        }
        return json['content'] as String;
      } catch (e) {
        trace?.parseError(response.statusCode);
        throw RemoteBackendException(
            'Failed to parse GitHub response (${e.runtimeType})',
            statusCode: response.statusCode);
      }
    }
    _throwForStatus(response);
  }

  /// Decodes the Contents API envelope (also the blob API's `content`) into
  /// the ciphertext; throws [FormatException] (or a decoding error) on
  /// anything that is too large or no base64 text.
  Uint8List _decodeEnvelope(String rawEnvelope) {
    // Two base64 layers: the API's envelope (split with newlines, so
    // whitespace goes first), then the file itself, which is the
    // base64 text of the ciphertext. Its UTF-8 decoding throws on
    // non-text files, which lands in the caller's catch like any other
    // malformed response.
    //
    // Outer layer: base64 of the inner text (4/3 of it), checked coarsely
    // before whitespace is stripped (the API adds a newline every 60
    // characters), then exactly.
    var outerLimit = 4 * ((maxTextLength + 2) ~/ 3);
    if (rawEnvelope.length > 2 * outerLimit) {
      throw const FormatException('Response is too large');
    }
    var envelope = rawEnvelope.replaceAll(RegExp(r'\s'), '');
    if (envelope.length > outerLimit) {
      throw const FormatException('Response is too large');
    }
    var text = utf8.decode(base64.decode(envelope));
    // Inner layer: the file text, capped before decoding.
    var inner = text.replaceAll(RegExp(r'\s'), '');
    if (inner.length > maxTextLength) {
      throw const FormatException('File is too large');
    }
    return Uint8List.fromList(base64.decode(inner));
  }

  /// Maps a failed (non-2xx, not handled by the caller) response of [read]:
  /// rate limit first, so a healthy token is never reported as rejected.
  Never _throwForStatus(http.Response response) {
    _throwIfRateLimited(response);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw RemoteAuthException('GitHub rejected the stored token',
          statusCode: response.statusCode);
    }
    throw RemoteBackendException(
        'GitHub request failed with status ${response.statusCode}',
        statusCode: response.statusCode);
  }

  /// Writes [bytes] to the database's file as base64 text (see the class doc).
  /// [version] is the `sha` the previous [read] returned: null creates the
  /// file, non-null updates it. A stale
  /// or missing `sha` on an existing file fails with
  /// [RemoteConflictException], which is the whole point of threading the
  /// version through instead of blind overwriting.
  ///
  /// Returns the new `sha` from the API response.
  @override
  Future<String?> write(String name, Uint8List bytes, {String? version}) async {
    // Fixed message on purpose: nothing about the database may end up in
    // the git history in the clear, where — unlike a file path — it could
    // never be renamed away again.
    var body = <String, dynamic>{
      'message': 'Save database',
      // The file content is the base64 text; the API then wants that
      // content base64-encoded itself.
      'content': base64.encode(utf8.encode(base64.encode(bytes))),
      if (branch.isNotEmpty) 'branch': branch,
      if (version != null) 'sha': version,
    };
    var trace = _trace('put', 'contents', name);
    http.Response response;
    try {
      response = await _send(_client, 'PUT', _writeUri(name),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
          timeout: requestTimeout,
          track: true,
          trace: trace);
    } on RemoteTimeoutException {
      rethrow;
    } catch (e) {
      throw RemoteBackendException(
          'Failed to write data to GitHub (${e.runtimeType})');
    }
    if (response.statusCode == 200 || response.statusCode == 201) {
      try {
        var json = jsonDecode(response.body) as Map<String, dynamic>;
        var content = json['content'] as Map<String, dynamic>?;
        return content?['sha'] as String?;
      } catch (e) {
        trace?.parseError(response.statusCode);
        throw RemoteBackendException(
            'Failed to parse GitHub response (${e.runtimeType})',
            statusCode: response.statusCode);
      }
    }
    _throwIfRateLimited(response);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw RemoteAuthException('GitHub rejected the stored token',
          statusCode: response.statusCode);
    }
    // 409: sha mismatch on update. 422: validation failed — for the
    // Contents API that is "sha wasn't supplied" (blind overwrite of an
    // existing file) or "sha is outdated". Both mean the remote state
    // moved since the read, so both are conflicts, not generic errors.
    if (response.statusCode == 409 || response.statusCode == 422) {
      throw RemoteConflictException('Remote database changed since it was read',
          statusCode: response.statusCode);
    }
    throw RemoteBackendException(
        'GitHub request failed with status ${response.statusCode}',
        statusCode: response.statusCode);
  }

  /// Deletes the database's file (Contents API `DELETE`). Used when a
  /// passphrase change moves a database to a new name (see [pathFor]) and
  /// the file under the old name must not be left behind.
  ///
  /// [version] is the blob `sha` a preceding [read] returned - the API
  /// requires it, the same way [write] does for an update. There is no
  /// "file already gone" special case here (unlike [read]'s 404 handling):
  /// callers only call this when they just read the file and got a version
  /// back, so a 404 here means it changed remotely in between, which is
  /// exactly the conflict [RemoteConflictException] below is for.
  @override
  Future<void> delete(String name, String version) async {
    // Fixed, neutral message, same reasoning as write()'s: it must not
    // record in the git history that a credential change happened here.
    var body = jsonEncode({
      'message': 'Delete database',
      'sha': version,
      if (branch.isNotEmpty) 'branch': branch,
    });
    http.Response response;
    try {
      response = await _send(_client, 'DELETE', _writeUri(name),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: body,
          timeout: requestTimeout,
          track: true,
          trace: _trace('delete', 'contents', name));
    } on RemoteTimeoutException {
      rethrow;
    } catch (e) {
      throw RemoteBackendException(
          'Failed to delete data on GitHub (${e.runtimeType})');
    }
    if (response.statusCode == 200) {
      return;
    }
    _throwIfRateLimited(response);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw RemoteAuthException('GitHub rejected the stored token',
          statusCode: response.statusCode);
    }
    if (response.statusCode == 404 ||
        response.statusCode == 409 ||
        response.statusCode == 422) {
      throw RemoteConflictException('Remote database changed since it was read',
          statusCode: response.statusCode);
    }
    throw RemoteBackendException(
        'GitHub request failed with status ${response.statusCode}',
        statusCode: response.statusCode);
  }

  /// Resolves the login the token belongs to (`GET /user`), stored as
  /// `owner` in the database's GitHub settings at setup/token-replacement
  /// time so a normal sync never needs this request.
  static Future<String> resolveOwner(String token,
      {http.Client? client,
      Duration requestTimeout = defaultRequestTimeout,
      SyncLog? log}) async {
    var httpClient = client ?? http.Client();
    var closeClient = client == null;
    try {
      var response = await _send(httpClient, 'GET', Uri.parse('$apiBase/user'),
          headers: {
            'Accept': 'application/vnd.github+json',
            'Authorization': 'Bearer $token',
            'X-GitHub-Api-Version': '2022-11-28',
          },
          timeout: requestTimeout,
          trace: log == null
              ? null
              : _Trace(log, 'resolve owner', 'user', token: token));
      _throwIfRateLimited(response);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw RemoteAuthException('GitHub rejected the token',
            statusCode: response.statusCode);
      }
      if (response.statusCode != 200) {
        throw RemoteBackendException(
            'GitHub request failed with status ${response.statusCode}',
            statusCode: response.statusCode);
      }
      try {
        return (jsonDecode(response.body) as Map<String, dynamic>)['login']
            as String;
      } catch (e) {
        throw RemoteBackendException(
            'Failed to parse GitHub response (${e.runtimeType})',
            statusCode: response.statusCode);
      }
    } catch (e) {
      if (e is RemoteBackendException) rethrow;
      throw RemoteBackendException('Failed to reach GitHub (${e.runtimeType})');
    } finally {
      if (closeClient) httpClient.close();
    }
  }

  @override
  void close() => _client.close();
}

/// Throws [RemoteRateLimitException] if [response] is a GitHub rate-limit
/// refusal: always for `429`; for `403` only with a rate-limit mark, i.e.
/// `x-ratelimit-remaining: 0`, a `retry-after` header, or a body containing
/// "rate limit" (case-insensitive, which also covers the secondary limits).
/// Every other status passes through to the caller's auth/error mapping.
/// Neither the body nor the token ends up in the message.
void _throwIfRateLimited(http.Response response) {
  if (!_isRateLimited(response)) return;
  throw RemoteRateLimitException('GitHub rate limit reached, try again later',
      statusCode: response.statusCode,
      retryAfter: _parseRetryAfter(_header(response, 'retry-after')));
}

/// Die Entscheidung von [_throwIfRateLimited], auch für das Sync-Log.
bool _isRateLimited(http.Response response) {
  var status = response.statusCode;
  if (status != 429 && status != 403) return false;
  if (status == 429) return true;
  return _header(response, 'x-ratelimit-remaining') == '0' ||
      _header(response, 'retry-after') != null ||
      response.body.toLowerCase().contains('rate limit');
}

/// Case-insensitive header lookup: HTTP header names are case-insensitive,
/// and the map in a response is not guaranteed to be normalised.
String? _header(http.Response response, String name) {
  for (var entry in response.headers.entries) {
    if (entry.key.toLowerCase() == name) return entry.value;
  }
  return null;
}

/// `Retry-After` in delta-seconds. The HTTP-date form is not parsed: the
/// refusal is still a rate limit, only [RemoteRateLimitException.retryAfter]
/// stays null.
Duration? _parseRetryAfter(String? value) {
  var seconds = int.tryParse(value?.trim() ?? '');
  return seconds == null ? null : Duration(seconds: seconds);
}

/// ".txt" o. ä.: die Endung des Pfads, die im Log unmaskiert bleibt.
String _suffix(String path) => path.endsWith('.txt') ? '.txt' : '';

/// Schreibt eine Anfrage und ihre Antwort ins [SyncLog]. Jeder Aufruf fängt
/// alle Fehler (das Log darf den Sync nie stören).
///
/// Was hineinkommt: Operation, Methode, Endpunkt-Kategorie, Status, Ergebnis,
/// bei Fehlerantworten `message`/`documentation_url` des GitHub-Fehler-JSON,
/// owner/repo/branch, der maskierte Pfad und eine feste Auswahl harmloser
/// Header. NIE: URL, Query, Token, Header `Authorization`, Body einer
/// erfolgreichen Antwort (enthält den Dateiinhalt), der volle Name, die
/// Ausnahmetexte der Clients (`ClientException` nennt die URL).
class _Trace {
  static const _headerWhitelist = [
    'x-github-request-id',
    'x-ratelimit-remaining',
    'x-accepted-github-permissions',
    // Ein classic Token ohne repo-Scope bekommt bei einem privaten Repo ein
    // nacktes 404: die Scopes (Namen, keine Geheimnisse) erklären das.
    'x-oauth-scopes',
    'x-accepted-oauth-scopes',
    'github-authentication-token-expiration',
    'retry-after',
  ];

  /// Muster bekannter GitHub-Token (classic und fine-grained).
  static final RegExp _tokenPattern =
      RegExp(r'(gh[pousr]|github_pat)_[A-Za-z0-9_]+');
  static final RegExp _longRun = RegExp(r'[A-Za-z0-9+/=_-]{40,}');
  static const int _fragmentLength = 8;

  final SyncLog log;
  final String operation;
  final String endpoint;
  final String? _owner;
  final String? _repo;
  final String? _branch;
  final String? name;
  final String? pathSuffix;
  final String token;

  /// Epoche des Logs beim Start der Anfrage (siehe [SyncLog.epoch]).
  final int _epoch;

  _Trace(this.log, this.operation, this.endpoint,
      {String? owner,
      String? repo,
      String? branch,
      this.name,
      this.pathSuffix,
      required this.token,
      int? epoch})
      : _epoch = epoch ?? log.epoch,
        _owner = owner,
        _repo = repo,
        _branch = branch;

  // Auch Konto, Repo und Branch laufen durch den Scrub: ein vertipptes
  // Token im Repo-Feld darf nicht im Log landen.
  String? get owner => _owner == null ? null : _scrub(_owner!, runs: false);
  String? get repo => _repo == null ? null : _scrub(_repo!, runs: false);
  String? get branch => _branch == null ? null : _scrub(_branch!, runs: false);

  /// Die ersten Zeichen des Namens (höchstens 6, nie mehr als die Hälfte).
  String? get _maskedPath {
    var n = name;
    if (n == null) return null;
    var shown = n.length ~/ 2 < 6 ? n.length ~/ 2 : 6;
    return '${n.substring(0, shown)}...<${pathSuffix ?? ''}';
  }

  /// Entfernt, was nie ins Log darf, auch wenn GitHub oder ein Tippfehler es
  /// wiederholt. Garantiert: der exakte Token, seine URL-codierte Form, jedes
  /// Teilstück ab 8 Zeichen (auch über Zeilenumbrüche verteilt), bekannte
  /// Token-Muster (`ghp_...`, `github_pat_...`), der exakte Name (auch codiert).
  /// Nur best effort (mit [runs]): lange base64-artige Folgen, die auch
  /// Inhalt sein könnten. Whitespace wird vor dem Scrub zu einem Leerzeichen,
  /// damit Umbrüche ein Geheimnis nicht zerschneiden.
  String _scrub(String text, {bool runs = true}) {
    var out = text.replaceAll(RegExp(r'\s+'), ' ');
    var n = name?.trim();
    var fragments = <String>[
      for (var i = 0; i + _fragmentLength <= token.length; i++)
        token.substring(i, i + _fragmentLength)
    ];
    var whole = <String>[
      token,
      Uri.encodeComponent(token),
      if (n != null) n,
      if (n != null) Uri.encodeComponent(n),
    ];
    for (var secret in whole) {
      if (secret.isNotEmpty) out = out.replaceAll(secret, '[redacted]');
    }
    out = out.replaceAll(_tokenPattern, '[redacted]');
    for (var fragment in fragments) {
      out = out.replaceAll(fragment, '[redacted]');
    }
    // Ein Rest, der erst ohne Leerzeichen ein Teilstück ergibt (Umbruch
    // mitten im Token): lieber alles weglassen.
    var squashed = out.replaceAll(' ', '');
    if (fragments.any(squashed.contains) ||
        whole.any((w) => w.isNotEmpty && squashed.contains(w))) {
      return '[redacted]';
    }
    return runs ? out.replaceAll(_longRun, '[redacted]') : out;
  }

  static String _resultFor(String operation, http.Response response) {
    var status = response.statusCode;
    if (status >= 200 && status < 300) return 'ok';
    if (_isRateLimited(response)) return 'rateLimit';
    if (status == 401 || status == 403) return 'authRequired';
    if (status == 404) {
      if (operation == 'read file') return 'remoteMissing';
      if (operation == 'delete') return 'conflict';
      return 'notFound';
    }
    if ((status == 409 || status == 422) &&
        (operation == 'put' || operation == 'delete')) {
      return 'conflict';
    }
    return 'httpError';
  }

  void response(String method, http.Response response) {
    try {
      String? message;
      String? documentationUrl;
      var status = response.statusCode;
      // Nur Fehlerantworten: ein 2xx-Body enthält den Dateiinhalt.
      if (status < 200 || status >= 300) {
        try {
          var json = jsonDecode(response.body);
          if (json is Map) {
            var m = json['message'];
            var d = json['documentation_url'];
            if (m is String) {
              // Erst bereinigen, dann kürzen: sonst schneidet das Kürzen ein
              // wiederholtes Geheimnis in einen nicht mehr erkennbaren Rest.
              message = SyncLog.clip(_scrub(m));
            }
            // Nur Links auf die GitHub-Doku, ohne Query (dort könnte etwas
            // stehen) und ohne die base64-Regel (Doku-Pfade sind lang).
            if (d is String && d.startsWith('https://docs.github.com/')) {
              documentationUrl =
                  SyncLog.clip(_scrub(d.split('?').first, runs: false));
            }
          }
        } catch (_) {
          // Kein JSON: weglassen.
        }
      }
      var headers = <String, String>{};
      for (var h in _headerWhitelist) {
        var v = _header(response, h);
        if (v != null) headers[h] = _scrub(v);
      }
      log.record(
          epoch: _epoch,
          operation: operation,
          method: method,
          endpoint: endpoint,
          status: status,
          result: _resultFor(operation, response),
          message: message,
          documentationUrl: documentationUrl,
          owner: owner,
          repo: repo,
          branch: branch,
          path: _maskedPath,
          headers: headers);
    } catch (_) {
      // Die Diagnose darf nie einen Fehler auslösen.
    }
  }

  /// Die Antwort war da, ließ sich aber nicht auswerten (nur der Status).
  void parseError(int status) {
    try {
      log.record(
          epoch: _epoch,
          operation: operation,
          result: 'parseError',
          status: status,
          owner: owner,
          repo: repo,
          branch: branch);
    } catch (_) {}
  }

  /// Transportfehler: nur der Typ, nie `toString()` (nennt die URL).
  void failure(String method, Object error) {
    try {
      log.record(
          epoch: _epoch,
          operation: operation,
          method: method,
          endpoint: endpoint,
          result: 'network',
          owner: owner,
          repo: repo,
          branch: branch,
          path: _maskedPath,
          detail: 'error: ${error.runtimeType}');
    } catch (_) {}
  }

  void timeout(String method, Duration timeout) {
    try {
      log.record(
          epoch: _epoch,
          operation: operation,
          method: method,
          endpoint: endpoint,
          result: 'timeout',
          owner: owner,
          repo: repo,
          branch: branch,
          path: _maskedPath,
          detail: 'aborted after ${timeout.inMilliseconds} ms');
    } catch (_) {}
  }
}
