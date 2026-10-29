import 'dart:async';

/// Zustand der Synchronisation einer geöffneten Datenbank mit ihrem Remote
/// (siehe `UltracipherApp.syncStatus`).
enum SyncState {
  /// Der lokale Stand entspricht dem letzten gelesenen/geschriebenen Remote.
  synced,

  /// Ein Sync läuft (oder ein Folgelauf steht an).
  syncing,

  /// Lokale Änderungen sind (noch) nicht auf dem Remote: Netz-/Serverfehler,
  /// Rate-Limit, Konflikte über dem Limit oder eine nicht lesbare
  /// Remote-Datei. Lokal bleibt alles gespeichert. [SyncStatus.error] sagt
  /// warum.
  notSynced,

  /// Das Remote hat die Zugangsdaten abgelehnt.
  authRequired,

  /// Die Remote-Datei existiert nicht (mehr). Kein automatisches Anlegen.
  remoteMissing,

  /// Es ist kein Remote konfiguriert (oder keine Datenbank offen).
  noRemote,
}

/// Status für die UI: der [state] plus, was zur Anzeige nötig ist. Ein
/// unveränderlicher Wert; er liegt in einem `ValueNotifier`.
class SyncStatus {
  final SyncState state;

  /// Fehlertext zu [state] (nur bei `notSynced`, `authRequired`,
  /// `remoteMissing`). Enthält nie Token, URLs oder Klartext der Datenbank.
  final String? error;

  /// Nur bei einem Rate-Limit: die vom Server genannte Wartezeit (falls er
  /// eine genannt hat).
  final Duration? retryAfter;

  /// Nur bei einem Rate-Limit mit [retryAfter]: der Zeitpunkt, ab dem ein
  /// automatischer Trigger wieder anfragt. Es gibt dafür keinen Timer: der
  /// nächste Trigger nach diesem Zeitpunkt synct (ein ausdrückliches "Sync
  /// now" fragt immer an).
  final DateTime? retryAt;

  /// Die ursprüngliche Ausnahme zu [error], für Aufrufer, die sie
  /// weiterreichen müssen (`removeGithub`). Nicht für die Anzeige.
  final Object? cause;

  const SyncStatus(this.state,
      {this.error, this.retryAfter, this.retryAt, this.cause});

  static const SyncStatus synced = SyncStatus(SyncState.synced);
  static const SyncStatus syncing = SyncStatus(SyncState.syncing);
  static const SyncStatus noRemote = SyncStatus(SyncState.noRemote);
  static const SyncStatus notSynced = SyncStatus(SyncState.notSynced);

  @override
  String toString() => 'SyncStatus($state'
      '${error == null ? '' : ', error: $error'}'
      '${retryAfter == null ? '' : ', retryAfter: $retryAfter'})';
}

/// Höchstens eine Ausführung von [action] gleichzeitig.
///
/// [run] während eines laufenden Laufs startet nichts, sondern merkt genau
/// einen Folgelauf vor; alle [run]-Aufrufe während des Laufs bekommen
/// dasselbe Future dieses einen Folgelaufs (Coalescing). Fünf schnelle
/// Aufrufe ergeben also höchstens zwei Läufe: den ersten und einen
/// Folgelauf, der den Stand nach dem letzten Aufruf sieht.
///
/// Ein Aufrufer, dessen [run] mit einem laufenden Lauf zusammenfällt,
/// bekommt das Ergebnis des FOLGELAUFS, nie das des schon laufenden: dessen
/// Stand kann älter sein als die Änderung, wegen der der Aufrufer synct.
///
/// Es gibt keinen Timer und keine Wiederholung: der Folgelauf entsteht nur,
/// wenn [run] ihn angefordert hat. Dart ist single-threaded, die Zustände
/// werden nur synchron (zwischen zwei awaits) gelesen und gesetzt.
class SingleFlight<T> {
  final Future<T> Function() _action;

  Completer<T>? _running;
  Completer<T>? _next;

  /// Gesetzt, solange [exclusive] die Sperre hält.
  Completer<void>? _held;
  int _generation = 0;

  SingleFlight(this._action);

  /// Läuft gerade ein Lauf.
  bool get isRunning => _running != null;

  /// Hält gerade [exclusive] die Sperre.
  bool get isHeld => _held != null;

  /// Steht ein Folgelauf an.
  bool get hasPending => _next != null;

  /// Wird erfüllt, sobald weder ein Lauf läuft noch ein Folgelauf ansteht
  /// noch [exclusive] die Sperre hält. Fehler der Läufe werden hier nicht
  /// gemeldet.
  Future<void> get idle async {
    while (_running != null || _held != null) {
      try {
        await (_next?.future ?? _running?.future ?? _held!.future);
      } catch (_) {
        // Fehler gehören den Aufrufern von run().
      }
    }
  }

  /// Führt [action] aus, während kein Lauf läuft: wartet erst, bis keiner
  /// mehr läuft, und hält dann die Sperre bis zum Ende von [action]. [run]
  /// startet währenddessen nichts, sondern merkt wie sonst den einen
  /// Folgelauf vor; er startet, sobald [action] fertig ist.
  ///
  /// [action] darf nicht auf [run] oder [idle] warten (beide warten auf das
  /// Ende von [action]). [reset] gibt die Sperre frei; [action] läuft dann
  /// weiter und muss selbst prüfen, ob ihr Ergebnis noch gilt.
  Future<R> exclusive<R>(Future<R> Function() action) async {
    // Prüfen und Sperren ohne await dazwischen: sonst könnte ein Lauf
    // dazwischen starten.
    while (_running != null || _held != null) {
      await idle;
    }
    var generation = _generation;
    var held = _held = Completer<void>();
    try {
      return await action();
    } finally {
      if (generation == _generation) {
        _held = null;
        var next = _next;
        _next = null;
        if (next != null) {
          _execute(next);
        }
      }
      if (!held.isCompleted) {
        held.complete();
      }
    }
  }

  /// Startet einen Lauf oder, wenn gerade einer läuft, fordert den Folgelauf
  /// an (siehe Klassenkommentar). Das Future liefert das Ergebnis des Laufs,
  /// der den Aufrufer abdeckt.
  Future<T> run() {
    if (_running == null && _held == null) {
      var completer = Completer<T>();
      _execute(completer);
      return completer.future;
    }
    return (_next ??= Completer<T>()).future;
  }

  /// Gibt den laufenden Lauf auf, damit er nicht länger blockiert: ein Lauf,
  /// der zu einer beendeten Sitzung gehört und im Netz hängt, soll den ersten
  /// Lauf der nächsten Sitzung nicht aufhalten. Der aufgegebene Lauf läuft
  /// weiter (Dart kann ihn nicht abbrechen), fasst aber die Zustände dieser
  /// Klasse nicht mehr an; seine Aufrufer und die des vorgemerkten
  /// Folgelaufs bekommen sofort [valueForAbandoned]. Es startet nichts: der
  /// Aufrufer richtet erst den neuen Zustand ein und ruft dann [run].
  void reset(T valueForAbandoned) {
    _generation++;
    var running = _running;
    var next = _next;
    var held = _held;
    _running = null;
    _next = null;
    _held = null;
    if (held != null && !held.isCompleted) {
      held.complete();
    }
    if (running != null && !running.isCompleted) {
      running.complete(valueForAbandoned);
    }
    if (next != null && !next.isCompleted) {
      next.complete(valueForAbandoned);
    }
  }

  Future<void> _execute(Completer<T> completer) async {
    var generation = _generation;
    _running = completer;
    T? value;
    Object? error;
    StackTrace? stack;
    var failed = false;
    try {
      value = await _action();
    } catch (e, s) {
      failed = true;
      error = e;
      stack = s;
    }
    // Zustand zuerst fortschreiben, dann erst die Aufrufer wecken: ein
    // Aufrufer, der sofort wieder run() ruft, soll den Folgelauf nicht
    // doppeln. Nach reset() gehört der Zustand schon einem neueren Lauf.
    if (generation == _generation) {
      var next = _next;
      _next = null;
      _running = null;
      if (next != null) {
        _execute(next);
      }
    }
    if (completer.isCompleted) {
      return;
    }
    if (failed) {
      completer.completeError(error!, stack);
    } else {
      completer.complete(value as T);
    }
  }
}
