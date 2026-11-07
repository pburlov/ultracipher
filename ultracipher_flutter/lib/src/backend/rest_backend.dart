import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../crypto/format_v1.dart' show maxFileLength;
import '../sync_log.dart';
import 'remote_backend.dart';

/// [RemoteBackend] für einen eigenen Sync-Server (REST), die zweite
/// Möglichkeit neben [GithubBackend].
///
/// Die Datei der Datenbank liegt unter `<url>/<name>`; `<name>` ist der
/// Datenbankname (base64url, 43 Zeichen, braucht kein Escaping). Der Server
/// bekommt und liefert die Bytes, die `UltracipherApp.encryptDatabase`
/// erzeugt, roh (`application/octet-stream`, kein base64), also genau den
/// Inhalt der GitHub-Datei, nur ohne die Textkodierung. Es gibt keine
/// Anmeldung; der Schutz ist der Name (256 Bit) und die Verschlüsselung.
///
/// Protokoll (bedingte Anfragen nach HTTP-Standard; die Version ist das ETag):
///
/// | Anfrage | Bedeutung | Antworten |
/// |---|---|---|
/// | `GET <url>/<name>` | lesen | `200` Rohbytes + `ETag`; `404` fehlt |
/// | `PUT` mit `If-None-Match: *` | anlegen ([write] ohne `version`) | `201` + `ETag`; `412` existiert schon |
/// | `PUT` mit `If-Match: "<etag>"` | ersetzen | `200` + `ETag`; `412` andere Version oder fehlt |
/// | `DELETE` mit `If-Match: "<etag>"` | löschen | `204`; `412`/`404` Konflikt |
///
/// Abbildung der Antworten:
/// - `404` beim Lesen ist keine Störung, sondern leere [RemoteData] (die
///   Datei fehlt); der Aufrufer entscheidet, was das heißt.
/// - `412` (beim Löschen auch `404`) wird zur [RemoteConflictException].
/// - `429` wird zur [RemoteRateLimitException] (mit `Retry-After` in Sekunden).
/// - Jeder andere Status wird zur [RemoteBackendException] mit `statusCode`
///   und führt zu `notSynced`. Auch ein `200` ohne `ETag` (im Browser blendet
///   CORS ihn aus, wenn der Server ihn nicht freigibt) und ein `200` ohne
///   Inhalt sind Fehler: ohne Version könnte der Sync nur mit `If-None-Match:
///   *` schreiben und liefe in einen endlosen `412`, und eine leere Antwort
///   gälte dem Sync als "Datei fehlt" und legte sie neu an.
/// - Es gibt hier nie [RemoteAuthException]: ohne Anmeldung kann nichts
///   abgelehnt werden (ein `401`/`403` ist eine Störung des Servers oder der
///   Freigabe, kein Grund, ein Token abzufragen).
/// - Eine Anfrage ohne Antwort binnen [requestTimeout] wird wirklich
///   abgebrochen (`http.AbortableRequest`) und ist eine
///   [RemoteTimeoutException].
///
/// Die URL kann einen geheimen Pfadteil tragen. Sie steht deshalb in keiner
/// Meldung und im Sync-Log nur als Host.
class RestBackend implements RemoteBackend {
  /// Name in der Oberfläche und in [RemoteTimeoutException].
  static const String backendName = syncServerDisplayName;

  /// Default for [requestTimeout].
  static const Duration defaultRequestTimeout = Duration(seconds: 30);

  /// Schreib- und Löschaufrufe (PUT/DELETE), die noch unterwegs sind.
  /// Prozessweit wie bei [GithubBackend]: ein abgebrochener Sync einer
  /// früheren Sitzung schreibt über ein anderes Objekt an dieselbe Datei.
  /// Ein Aufruf zählt als erledigt, sobald seine Anfrage endet oder der
  /// Timeout sie abgebrochen hat. Restrisiko (der übliche Timeout-Fall): der
  /// Body war schon gesendet und der Server verarbeitet ihn trotzdem; die
  /// Bedingung `If-Match` lässt veraltete Aufrufe aber scheitern, statt etwas
  /// zu überschreiben.
  static final Set<Future<void>> _pendingWrites = {};

  /// Prüft und normalisiert die Basis-URL des Servers (für den Eingabedialog
  /// und für jede Anfrage). Gibt die URL ohne abschließenden `/` zurück und
  /// wirft sonst eine [FormatException], deren Meldung für den Nutzer ist und
  /// die URL nie enthält.
  ///
  /// - `https://` ist Pflicht; `http://` nur für `localhost` und `127.0.0.1`
  ///   (Firebase-Emulator).
  /// - Keine Zugangsdaten in der URL, keine Query, kein Fragment (auch kein
  ///   leeres `?`/`#`): `<url>/<name>` wird einfach angehängt.
  /// - Das Ergebnis ist kanonisch: Schema und Host klein, Standardport
  ///   entfernt, Punktsegmente im Pfad aufgelöst (`/a/../ucdb` wird
  ///   `/ucdb`), kein abschließender `/`. Der Vergleich zweier URLs (Ortswechsel
  ///   beim Einrichten) darf nicht an der Schreibweise hängen.
  static String normalizeUrl(String input) {
    var text = input.trim();
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.isEmpty) {
      throw const FormatException('Enter the address of the sync server');
    }
    const invalid = 'The address of the sync server is not valid. Enter the '
        'full address, for example https://example.com/ucdb';
    if (RegExp(r'\s').hasMatch(text)) throw const FormatException(invalid);
    Uri uri;
    try {
      uri = Uri.parse(text);
    } on FormatException {
      throw const FormatException(invalid);
    }
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException(invalid);
    }
    var local = uri.host == 'localhost' || uri.host == '127.0.0.1';
    if (!(uri.scheme == 'https' || (uri.scheme == 'http' && local))) {
      throw const FormatException('The address of the sync server must start '
          'with https:// (http:// is only allowed for localhost)');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException('The address of the sync server must not '
          'contain a user name or password');
    }
    if (uri.hasQuery || uri.hasFragment) {
      throw const FormatException('The address of the sync server must not '
          'contain a query ("?") or a fragment ("#")');
    }
    var path = uri.normalizePath().path;
    var port = uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80)
        ? ':${uri.port}'
        : '';
    var host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    var canonical = '${uri.scheme}://$host$port$path';
    while (canonical.endsWith('/')) {
      canonical = canonical.substring(0, canonical.length - 1);
    }
    return canonical;
  }

  /// Upper bound for one HTTP call, the body included. A hanging connection
  /// must not block the sync (one run at a time) for good.
  final Duration requestTimeout;

  /// Obergrenze der Antwort in Bytes, vor jeder Entschlüsselung geprüft
  /// (Standard: das Leselimit der App, [maxFileLength]); nur Tests senken sie.
  final int maxResponseLength;

  /// Die konfigurierte Basis-URL. Sie wird erst bei einer Anfrage geprüft
  /// ([normalizeUrl]): eine ungültige URL in einer fremden Einstellung darf
  /// das Öffnen der Datenbank nicht verhindern, der Sync meldet sie dann.
  final String url;

  final http.Client _client;

  /// Sync-Log (nur im Speicher); `null` loggt nichts. Siehe [_Trace].
  final SyncLog? log;

  RestBackend({
    required this.url,
    http.Client? client,
    this.requestTimeout = defaultRequestTimeout,
    this.maxResponseLength = maxFileLength,
    this.log,
  }) : _client = client ?? http.Client();

  @override
  String get id => 'rest';

  @override
  String get displayName => backendName;

  /// Die Adresse der Datei zu [dbName], oder eine [RemoteBackendException]
  /// ohne die URL im Text, wenn die URL ungültig ist.
  Uri _uriFor(String dbName) {
    String base;
    try {
      base = normalizeUrl(url);
    } on FormatException catch (e) {
      throw RemoteBackendException(e.message);
    }
    return Uri.parse('$base/${Uri.encodeComponent(dbName.trim())}');
  }

  /// Host der URL fürs Sync-Log (nie Pfad oder Query), oder `null`.
  String? get _host {
    try {
      var host = Uri.parse(url.trim()).host;
      return host.isEmpty ? null : host;
    } catch (_) {
      return null;
    }
  }

  _Trace? _trace(String operation, String dbName) {
    var log = this.log;
    if (log == null) return null;
    return _Trace(log, operation, dbName, _host);
  }

  /// Sendet eine Anfrage als [http.AbortableRequest] und liest die Antwort
  /// samt Body (höchstens [maxResponseLength]). Nach [requestTimeout] wird sie
  /// wirklich abgebrochen und der Aufruf wirft [RemoteTimeoutException]; der
  /// zusätzliche `Future.timeout` ist das Sicherheitsnetz für einen Client, der
  /// den Abbruch nicht beachtet. [track] trägt PUT/DELETE in [_pendingWrites]
  /// ein.
  Future<http.Response> _send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
    bool track = false,
    _Trace? trace,
  }) {
    var abort = Completer<void>();
    var request = http.AbortableRequest(method, uri,
        abortTrigger: abort.future)
      ..headers.addAll(headers);
    if (body != null) request.bodyBytes = body;

    var settled = Completer<void>();
    void finish() {
      if (!settled.isCompleted) settled.complete();
      _pendingWrites.remove(settled.future);
    }

    if (track) _pendingWrites.add(settled.future);
    var call = (() async {
      var streamed = await _client.send(request);
      return _collect(streamed, () {
        if (!abort.isCompleted) abort.complete();
      });
    })();
    if (track) {
      call.then<void>((_) => finish(), onError: (Object _) => finish());
    }
    // Nur mithören (Sync-Log), wie bei GithubBackend: nach einem Timeout gibt
    // es genau einen Eintrag.
    var timedOut = false;
    if (trace != null) {
      call.then<void>((response) {
        if (!timedOut) trace.response(method, response);
      }, onError: (Object e) {
        if (!timedOut) trace.failure(method, e);
      });
    }
    return call.timeout(requestTimeout, onTimeout: () {
      timedOut = true;
      trace?.timeout(method, requestTimeout);
      if (!abort.isCompleted) abort.complete();
      finish();
      throw RemoteTimeoutException(requestTimeout, backendName);
    });
  }

  /// Liest den Body der Antwort, bricht aber bei mehr als [maxResponseLength]
  /// Bytes ab (zuerst nach `Content-Length`, dann beim Lesen), damit ein
  /// falsch konfigurierter Server nicht den Speicher füllt.
  Future<http.Response> _collect(
      http.StreamedResponse streamed, void Function() abort) async {
    var tooLarge = RemoteBackendException(
        'The sync server answered with more than '
        '${maxResponseLength ~/ (1024 * 1024)} MB',
        statusCode: streamed.statusCode);
    var declared = streamed.contentLength;
    if (declared != null && declared > maxResponseLength) {
      abort();
      throw tooLarge;
    }
    var builder = BytesBuilder(copy: false);
    await for (var chunk in streamed.stream) {
      builder.add(chunk);
      if (builder.length > maxResponseLength) {
        abort();
        throw tooLarge;
      }
    }
    return http.Response.bytes(builder.takeBytes(), streamed.statusCode,
        headers: streamed.headers,
        request: streamed.request,
        reasonPhrase: streamed.reasonPhrase);
  }

  /// [_send] mit der gemeinsamen Abbildung von Transportfehlern: ein Timeout
  /// und unsere eigenen Fehler gehen unverändert durch, alles andere wird zu
  /// einer [RemoteBackendException] ohne Ausnahmetext (der nennt die URL).
  Future<http.Response> _request(
    String action,
    String method,
    String dbName, {
    Map<String, String> headers = const {},
    Uint8List? body,
    bool track = false,
    _Trace? trace,
  }) async {
    var uri = _uriFor(dbName);
    try {
      return await _send(method, uri,
          headers: headers, body: body, track: track, trace: trace);
    } on RemoteBackendException {
      rethrow;
    } catch (e) {
      throw RemoteBackendException(
          'Failed to $action the sync server (${e.runtimeType})');
    }
  }

  /// 404 (noch keine Datei) ist keine Störung: leere Bytes ohne Version.
  /// Eine 200-Antwort ohne ETag oder ohne Inhalt ist ein Fehler (siehe die
  /// Klasse).
  @override
  Future<RemoteData> read(String name) async {
    var trace = _trace('read file', name);
    var response = await _request('read data from', 'GET', name,
        headers: const {'Accept': 'application/octet-stream'}, trace: trace);
    if (response.statusCode == 200) {
      var version = _etag(response);
      if (response.bodyBytes.isEmpty) {
        trace?.parseError(response.statusCode);
        throw RemoteBackendException(
            'The sync server answered without any data',
            statusCode: response.statusCode);
      }
      if (version == null) {
        trace?.parseError(response.statusCode);
        throw RemoteBackendException(_noEtagMessage,
            statusCode: response.statusCode);
      }
      return RemoteData(bytes: response.bodyBytes, version: version);
    }
    if (response.statusCode == 404) {
      return RemoteData(bytes: Uint8List(0), version: null);
    }
    _throwForStatus(response);
  }

  static const String _noEtagMessage = 'The sync server sent no version '
      '(ETag header). If this is the web app, the server must expose the '
      'ETag header to the browser (Access-Control-Expose-Headers).';

  /// [version] null legt an (`If-None-Match: *`), sonst ersetzt es genau
  /// diese Version (`If-Match`). Gibt das neue ETag zurück; fehlt es in der
  /// Antwort, ist das ein Fehler (siehe die Klasse).
  @override
  Future<String?> write(String name, Uint8List bytes, {String? version}) async {
    var trace = _trace('put', name);
    var response = await _request('write data to', 'PUT', name,
        headers: {
          'Content-Type': 'application/octet-stream',
          if (version == null) 'If-None-Match': '*',
          if (version != null) 'If-Match': '"$version"',
        },
        body: bytes,
        track: true,
        trace: trace);
    var status = response.statusCode;
    if (status == 200 || status == 201) {
      var etag = _etag(response);
      if (etag == null) {
        trace?.parseError(status);
        throw RemoteBackendException(_noEtagMessage, statusCode: status);
      }
      return etag;
    }
    if (status == 412) {
      throw RemoteConflictException('Remote database changed since it was read',
          statusCode: status);
    }
    _throwForStatus(response);
  }

  /// Löscht die Datei in der Version [version]. Ein `404` heißt, dass sie
  /// sich zwischen Lesen und Löschen geändert hat (der Aufrufer liest dann
  /// neu), wie bei GitHub ein Konflikt.
  @override
  Future<void> delete(String name, String version) async {
    var response = await _request('delete data on', 'DELETE', name,
        headers: {'If-Match': '"$version"'},
        track: true,
        trace: _trace('delete', name));
    var status = response.statusCode;
    if (status == 204 || status == 200) return;
    if (status == 404 || status == 412) {
      throw RemoteConflictException('Remote database changed since it was read',
          statusCode: status);
    }
    _throwForStatus(response);
  }

  /// 429 und alles andere, was die Aufrufer nicht selbst abbilden.
  Never _throwForStatus(http.Response response) {
    var status = response.statusCode;
    if (status == 429) {
      throw RemoteRateLimitException(
          'The sync server limits the requests, try again later',
          statusCode: status,
          retryAfter: _parseRetryAfter(_header(response, 'retry-after')));
    }
    if (status == 413) {
      throw RemoteBackendException(
          'The sync server refused the database as too large',
          statusCode: status);
    }
    throw RemoteBackendException(
        'The sync server request failed with status $status',
        statusCode: status);
  }

  /// Die Version aus dem `ETag`-Header: ohne `W/` und Anführungszeichen,
  /// `null` wenn er fehlt oder leer ist.
  static String? _etag(http.Response response) {
    var raw = _header(response, 'etag');
    if (raw == null) return null;
    var value = raw.trim();
    if (value.startsWith('W/')) value = value.substring(2);
    value = value.replaceAll('"', '').trim();
    return value.isEmpty ? null : value;
  }

  @override
  Future<void> whenWritesSettled() async {
    while (_pendingWrites.isNotEmpty) {
      await Future.wait(_pendingWrites.toList());
    }
  }

  @override
  void close() => _client.close();
}

/// Case-insensitive header lookup (the map is not guaranteed normalised).
String? _header(http.Response response, String name) {
  for (var entry in response.headers.entries) {
    if (entry.key.toLowerCase() == name) return entry.value;
  }
  return null;
}

/// `Retry-After` in delta-seconds; the HTTP-date form is not parsed (the
/// refusal is still a rate limit, only `retryAfter` stays null).
Duration? _parseRetryAfter(String? value) {
  var seconds = int.tryParse(value?.trim() ?? '');
  return seconds == null ? null : Duration(seconds: seconds);
}

/// Schreibt eine Anfrage und ihre Antwort ins [SyncLog]. Jeder Aufruf fängt
/// alle Fehler (das Log darf den Sync nie stören).
///
/// Was hineinkommt: Operation, Methode, Status, Ergebnis, der Host der URL,
/// der maskierte Name und `Retry-After` (nur als Zahl). NIE: die URL (der Pfad kann ein
/// Geheimnis tragen), Query, Body (auch nicht der einer Fehlerantwort: ein
/// eigener Server kann dort alles schreiben), der volle Name, die
/// Ausnahmetexte der Clients (`ClientException` nennt die URL).
class _Trace {
  final SyncLog log;
  final String operation;
  final String _name;
  final String? _host;

  /// Epoche des Logs beim Start der Anfrage (siehe [SyncLog.epoch]).
  final int _epoch;

  _Trace(this.log, this.operation, this._name, this._host)
      : _epoch = log.epoch;

  /// Die ersten Zeichen des Namens (höchstens 6, nie mehr als die Hälfte).
  String get _maskedPath {
    var n = _name;
    var shown = n.length ~/ 2 < 6 ? n.length ~/ 2 : 6;
    return '${n.substring(0, shown)}...<';
  }

  /// Entfernt den exakten Namen (auch codiert), falls er im Host steckt oder
  /// ein Header ihn wiederholt.
  String _scrub(String text) {
    var out = text.replaceAll(RegExp(r'\s+'), ' ');
    var n = _name.trim();
    if (n.isNotEmpty) {
      out = out.replaceAll(n, '[redacted]');
      out = out.replaceAll(Uri.encodeComponent(n), '[redacted]');
    }
    return out;
  }

  String? get host => _host == null ? null : _scrub(_host!);

  static String _resultFor(String operation, int status) {
    if (status >= 200 && status < 300) return 'ok';
    if (status == 429) return 'rateLimit';
    if (status == 404) {
      if (operation == 'read file') return 'remoteMissing';
      if (operation == 'delete') return 'conflict';
      return 'notFound';
    }
    if (status == 412 && (operation == 'put' || operation == 'delete')) {
      return 'conflict';
    }
    return 'httpError';
  }

  void response(String method, http.Response response) {
    try {
      var headers = <String, String>{};
      // Nur Sekunden: ein eigener Server kann in den Header schreiben, was er
      // will (auch die URL oder den Namen).
      var retryAfter = int.tryParse(_header(response, 'retry-after')?.trim() ?? '');
      if (retryAfter != null) headers['retry-after'] = '$retryAfter';
      log.record(
          epoch: _epoch,
          operation: operation,
          method: method,
          endpoint: 'file',
          status: response.statusCode,
          result: _resultFor(operation, response.statusCode),
          host: host,
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
          host: host);
    } catch (_) {}
  }

  /// Transportfehler: nur der Typ, nie `toString()` (nennt die URL).
  void failure(String method, Object error) {
    try {
      log.record(
          epoch: _epoch,
          operation: operation,
          method: method,
          endpoint: 'file',
          result: 'network',
          host: host,
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
          endpoint: 'file',
          result: 'timeout',
          host: host,
          path: _maskedPath,
          detail: 'aborted after ${timeout.inMilliseconds} ms');
    } catch (_) {}
  }
}
