import 'dart:async';
import 'dart:typed_data';

/// Bytes plus an opaque version token identifying the remote state they were
/// read from (GitHub: blob `sha`). A backend without versions returns `null`.
class RemoteData {
  final Uint8List bytes;
  final String? version;

  RemoteData({required this.bytes, this.version});

  bool get isEmpty => bytes.isEmpty;
}

/// Base class for every failure a [RemoteBackend] can raise.
///
/// [toString] intentionally returns the bare [message], without an
/// `Exception: ` prefix: `commons.dart` and `login.dart` render
/// `snapshot.error.toString()` directly in the UI.
class RemoteBackendException implements Exception {
  final String message;
  final int? statusCode;

  RemoteBackendException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// The remote state changed since it was last read (optimistic-concurrency
/// conflict, e.g. GitHub's `409`/`422` "sha wasn't supplied"/outdated cases).
class RemoteConflictException extends RemoteBackendException {
  RemoteConflictException(String message, {int? statusCode})
      : super(message, statusCode: statusCode);
}

/// The credential used to talk to the backend was rejected (expired or
/// revoked). Only GitHub raises it; the sync server has no credential. The
/// sync reports `authRequired`; the user re-enters the token in "GitHub
/// settings".
class RemoteAuthException extends RemoteBackendException {
  RemoteAuthException(String message, {int? statusCode})
      : super(message, statusCode: statusCode);
}

/// The backend refused the request because of a rate limit (GitHub: `429`,
/// or a `403` carrying a rate-limit mark). The token is fine, so this is
/// deliberately not a [RemoteAuthException]: the UI must not ask for a new
/// token. [retryAfter] is set when the server sent a `Retry-After`
/// in seconds.
class RemoteRateLimitException extends RemoteBackendException {
  final Duration? retryAfter;

  RemoteRateLimitException(String message, {int? statusCode, this.retryAfter})
      : super(message, statusCode: statusCode);
}

/// The backend did not answer in time and the request was aborted. The
/// message is meant for the user (it reaches the sync status and the error
/// dialogs unchanged) and names neither token, owner, repository nor URL;
/// [backendName] is the backend's [RemoteBackend.displayName] ("GitHub",
/// "Sync server").
class RemoteTimeoutException extends RemoteBackendException {
  final Duration timeout;

  RemoteTimeoutException(this.timeout, String backendName)
      : super('$backendName did not respond within ${_describe(timeout)}. '
            'Check the network and try again.');

  static String _describe(Duration d) => d.inMilliseconds % 1000 == 0
      ? '${d.inSeconds} s'
      : '${d.inMilliseconds} ms';
}

/// [RemoteBackend.displayName] des Sync-Servers ([RestBackend]).
const String syncServerDisplayName = 'Sync server';

/// Der Name eines Backends mitten im Satz: [RemoteBackend.displayName]
/// "Sync server" heißt dort "the sync server", "GitHub" bleibt "GitHub".
String remoteNameInSentence(String displayName) =>
    displayName == syncServerDisplayName ? 'the sync server' : displayName;

/// A place to persist and retrieve the encrypted database. Implementations:
/// [GithubBackend] and [RestBackend] (own sync server). The seam also lets
/// tests fake the storage.
abstract class RemoteBackend {
  /// Stable identifier, e.g. `'github'`.
  String get id;

  /// Human-readable name, used in the UI.
  String get displayName;

  Future<RemoteData> read(String name);

  /// Returns the new version token (or `null` if the backend has none).
  Future<String?> write(String name, Uint8List bytes, {String? version});

  /// Löscht die Datei der Datenbank [name] in der Version [version] (aus [read]).
  /// Fehlt die Datei oder hat sie eine andere Version, wirft das eine
  /// [RemoteConflictException] (GithubBackend bildet 404, 409 und 422 gleich
  /// ab); der Aufrufer liest dann neu.
  Future<void> delete(String name, String version);

  /// Wird erfüllt, sobald kein [write] und kein [delete] mehr unterwegs
  /// ist. Ein Aufruf, den der Timeout abgebrochen hat, gilt als erledigt.
  /// Restrisiko (der übliche Timeout-Fall): war der Body schon gesendet,
  /// kann der Aufruf trotzdem noch ankommen; mögliche Folge ist eine
  /// wiederangelegte verwaiste Datei unter dem alten Namen, kein
  /// Datenverlust, und die Versionsprüfung des Backends lässt Veraltetes
  /// scheitern. Ignoriert ein Client den Abbruch, läuft der Aufruf weiter,
  /// gilt aber ebenfalls als erledigt. Der
  /// Passwortwechsel wartet darauf, bevor er die alte Datei liest und
  /// löscht (Plan R3).
  Future<void> whenWritesSettled();

  void close();
}
