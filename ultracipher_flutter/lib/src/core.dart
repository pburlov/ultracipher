import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultracipher_flutter/src/model/model.dart';

import 'backend/github_backend.dart';
import 'backend/remote_backend.dart';
import 'crypto/constant_time.dart';
import 'crypto/format_v1.dart';
import 'crypto/kdf_profile.dart' as kdf;
import 'db_codec.dart';
import 'sync.dart';
import 'user_key_hash.dart';

/// [UltracipherApp.openLocalDatabase] fand unter dem Namen dieser Passphrase
/// keine lokale Datenbank. Die Meldung ist neutral: ein Tippfehler im
/// Passwort ist von "gibt es nicht" nicht zu unterscheiden (und soll es auch
/// nicht sein).
class NoLocalDatabaseException implements Exception {
  @override
  String toString() => 'No database found for this password';
}

/// [UltracipherApp.createDatabase] findet unter diesem Namen schon eine lokale
/// Datenbank und überschreibt nie. Die UI bietet "Open existing" an. Ebenso
/// [UltracipherApp.changeDatabasePassphrase] unter dem Namen der neuen
/// Passphrase: es wurde nichts geändert, bei "ja" erneut mit `mergeLocal: true`.
class LocalDatabaseExistsException implements Exception {
  @override
  String toString() => 'A database for this password already exists on this '
      'device';
}

/// Die lokale Kopie unter dem Namen existiert, ist aber nicht lesbar
/// (beschädigt). Anders als [NoLocalDatabaseException] ist das eindeutig: ein
/// falsches Passwort ergibt einen anderen Namen, nie diesen Fehler. Die UI
/// bietet damit `UltracipherApp.removeLocalDatabase(passphrase: ...)` an.
/// Die Meldung nennt keinen Inhalt.
class LocalDatabaseUnreadableException implements Exception {
  final String detail;

  LocalDatabaseUnreadableException(this.detail);

  @override
  String toString() => 'The local copy of this database cannot be read '
      '($detail); it was left untouched';
}

/// [UltracipherApp.configureGithub] fand am Ziel keine Datei, und Anlegen ist
/// hier nur mit Bestätigung erlaubt (Plan §3.3/E3): die DB hatte schon GitHub
/// am selben Ort (Token-Neueingabe in `remoteMissing`). Eine fehlende Datei
/// heißt dann meist "Passphrase geändert", nicht "neu anlegen". Es wurde
/// nichts geändert; die UI fragt und ruft bei "ja" erneut mit
/// `confirmCreate: true`. Die Meldung nennt beide Wege.
class GithubFileMissingException implements Exception {
  @override
  String toString() => 'No database file found on GitHub at this location. '
      'If the passphrase was changed, use "Change passphrase"; otherwise '
      'create the file on GitHub.';
}

/// Ausgang von [UltracipherApp.configureGithub] und
/// [UltracipherApp.removeGithub] (Erfolg; Fehler werfen).
class GithubSettingsResult {
  /// Die Datei am neuen Ort wurde angelegt.
  final bool created;

  /// Fehler des Schreibens an den ALTEN Ort, falls es scheiterte (Repo-Wechsel:
  /// Weiterleitung nach E1; Entfernen: Weitergabe an andere Geräte). Der
  /// Vorgang selbst gilt trotzdem als gelungen; andere Geräte erfahren dann
  /// nichts. `null`: gelungen oder nicht nötig.
  final Exception? oldLocationError;

  GithubSettingsResult({this.created = false, this.oldLocationError});
}

/// Ausgang von [UltracipherApp.changeDatabasePassphrase] (Fehler vor dem
/// Wechsel werfen und ändern nichts).
class PassphraseChangeResult {
  /// Der Wechsel ist gelungen (die Sitzung läuft unter der neuen
  /// Passphrase), aber das Aufräumen nicht: die alte Datei auf GitHub und die
  /// alte lokale Kopie bleiben dann stehen, der alte Name bleibt
  /// lesbar. Andere Geräte synchronisieren so weiter gegen die alte Datei.
  /// Ausweg: die alte Passphrase öffnen und erneut auf die neue wechseln
  /// (mergt, dann wird aufgeräumt). `null`: alles aufgeräumt.
  final Exception? cleanupError;

  PassphraseChangeResult({this.cleanupError});
}

/// Parst [csv] und mergt die Einträge in [db], ohne zu speichern - getrennt
/// vom Speichern, damit das ohne Backend testbar ist (Regeln siehe
/// [UltracipherDatabase.importFromCsv]).
///
/// Die FormatException wird neu erzeugt, ohne den CSV-Inhalt als `source`:
/// showProgressDialog zeigt `error.toString()` an, und die Originalmeldung
/// würde den Dateiinhalt in den Dialog kopieren. Die Meldung des Modells
/// enthält nur Satznummern, nie Zellinhalte.
CsvImportResult importCsvInto(UltracipherDatabase db, String csv) {
  try {
    return db.importFromCsv(csv);
  } on FormatException catch (e) {
    throw FormatException('The file is not a valid CSV export. ${e.message}');
  }
}

/// [UltracipherApp.syncStatus], das sich merkt, ob in der Sitzung schon
/// einmal `synced` gesetzt wurde (egal von welchem Pfad aus). [_newSession]
/// setzt [sawSynced] zurück, bevor es den Anfangszustand der Sitzung setzt.
class _SyncStatusNotifier extends ValueNotifier<SyncStatus> {
  bool sawSynced = false;

  _SyncStatusNotifier() : super(SyncStatus.noRemote);

  @override
  set value(SyncStatus status) {
    if (status.state == SyncState.synced) sawSynced = true;
    super.value = status;
  }
}

class UltracipherApp {
  /// Testnaht: ersetzt die (teure) KDF-Ableitung von `R` in [deriveRoot].
  /// Bekommt `utf8(passphrase.trim())`. `null` (Standard) rechnet echt
  /// (Argon2id und scrypt, nativ parallel in zwei Isolates). Wird im
  /// aufrufenden Isolate gelesen, nicht im Worker.
  @visibleForTesting
  static Future<Uint8List> Function(Uint8List passphraseBytes)? rootDerivation;

  static UltracipherApp? _instance;

  /// `R` der offenen Sitzung (64 B), nie die Passphrase (E6): Speichern, Sync,
  /// Export und GitHub leiten damit nur die billigen Dateischlüssel ab.
  /// `null`, solange keine Sitzung offen ist.
  Uint8List? _root;

  /// Where the encrypted database is read from and written to. Built from the
  /// open database's `settings.github`; `null` while no GitHub is configured
  /// (a local-only database, no session open, after [closeDatabase]).
  /// Swappable (tests).
  RemoteBackend? remoteBackend;

  static UltracipherApp get instance {
    _instance ??= UltracipherApp();
    return _instance!;
  }

  SharedPreferences? storage;

  ValueNotifier<UltracipherDatabase?> loadedDatabase = ValueNotifier(null);

  Future<void> init() async {
    storage = await SharedPreferences.getInstance();
  }

  static const String PASSPHRASE_ALPHABET =
      '1234567890!#\$%^&*()_-+=?><|\'"qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM';

  static String generatePassphrase([int length = 16]) {
    var buf = StringBuffer();
    for (var i = 0; i < length; i++) {
      var ci = rnd.nextInt(PASSPHRASE_ALPHABET.length);
      buf.writeCharCode(PASSPHRASE_ALPHABET.codeUnitAt(ci));
    }
    return buf.toString();
  }

  /// Leitet `R` aus [passphrase] ab (getrimmt, UTF-8; Spezifikation §3).
  ///
  /// Nativ laufen Argon2id und scrypt gleichzeitig in zwei Worker-Isolates
  /// (Wartezeit = Maximum), im Web nacheinander (dort läuft alles im
  /// Haupt-Thread). Die Passphrase wird nicht gespeichert, und `R` entsteht
  /// nur aus beiden Ausgaben (§2.4).
  Future<Uint8List> deriveRoot(String passphrase) {
    final bytes = kdf.passphraseBytes(passphrase);
    final override = rootDerivation;
    if (override != null) return override(bytes);
    return deriveRootReal(bytes);
  }

  /// Die echte Ableitung ohne Testnaht (auch für Tests, deren Gegenstand sie
  /// ist, und für die Memoisierung der Testnaht).
  ///
  /// Läuft über `compute` (frische Isolates), nicht über einen Worker-Pool:
  /// dessen Größe hängt von der Kernzahl ab (auf einem Einkernrechner gäbe es
  /// keinen Worker, und die Aufgaben blieben ewig in der Warteschlange). So
  /// ist die Parallelität nicht vom Pool abhängig. Beide Wege münden in
  /// `combineRoot` (wie das synchrone `deriveRoot` in kdf_profile.dart); die
  /// eingefrorenen R-Tests binden sie aneinander.
  static Future<Uint8List> deriveRootReal(Uint8List passphraseBytes) async {
    final Uint8List ka;
    final Uint8List ks;
    if (kIsWeb) {
      ka = await compute(_argon2Task, passphraseBytes);
      ks = await compute(_scryptTask, passphraseBytes);
    } else {
      final results = await Future.wait<Uint8List>([
        compute(_argon2Task, passphraseBytes),
        compute(_scryptTask, passphraseBytes),
      ]);
      ka = results[0];
      ks = results[1];
    }
    return kdf.combineRoot(ka, ks, kdf.kdfProfile1);
  }

  static Uint8List _argon2Task(Uint8List passphraseBytes) =>
      kdf.deriveArgon2idKey(passphraseBytes, kdf.kdfProfile1);

  static Uint8List _scryptTask(Uint8List passphraseBytes) =>
      kdf.deriveScryptKey(passphraseBytes, kdf.kdfProfile1);

  /// Status der Synchronisation der geöffneten Sitzung, für die UI. Wird nur
  /// von der Sitzung beschrieben (siehe [_newSession] und [_syncOnce]).
  final ValueNotifier<SyncStatus> syncStatus = _SyncStatusNotifier();

  /// Sitzungszähler. Jeder Wechsel der Sitzung (Öffnen, Schließen, Wechsel
  /// der Passphrase) erhöht ihn über [_newSession]. Ein
  /// Sync merkt sich den Stand beim Start und prüft ihn nach jedem `await`
  /// ([_syncOnce]): ein Sync, der nach `closeDatabase` oder dem Öffnen einer
  /// anderen Datenbank zurückkommt, fasst weder die lokale Kopie noch [loadedDatabase]
  /// noch [syncStatus] an.
  int _session = 0;

  /// Zähler für Backend und Sync-Lauf: [_newSession] und [_replaceBackend]
  /// erhöhen ihn, ein Sync merkt ihn sich wie [_session] und verwirft sein
  /// Ergebnis, wenn er sich ändert. Ein Backend-Wechsel in derselben offenen
  /// Sitzung darf aber ein gerade laufendes Speichern nicht ungültig machen,
  /// das prüft nur [_session].
  int _syncEpoch = 0;

  /// Ob in der laufenden Sitzung schon einmal `synced` gesetzt wurde (vom Sync
  /// oder von `configureGithub`/dem Passphrase-Wechsel, die den Stand selbst
  /// schreiben). Davor ist offen, ob die lokalen Änderungen auf dem Remote
  /// sind ("Sync status unknown", Plan §3.3): die UI versucht dann vor
  /// Schließen/Entfernen erst einen Sync. Wird von [_newSession] gelöscht.
  bool get hasSyncedThisSession =>
      (syncStatus as _SyncStatusNotifier).sawSynced;

  /// Wie viele Schreibversuche ein Sync-Lauf höchstens macht. Jeder Versuch
  /// ist: Remote lesen, mergen, lokal speichern, schreiben; nur ein
  /// [RemoteConflictException] beim Schreiben führt zum nächsten Versuch.
  /// Danach bleibt es bei `notSynced`, der nächste Trigger probiert neu.
  static const int MAX_SYNC_ATTEMPTS = 3;

  static const SyncStatus _remoteMissing = SyncStatus(SyncState.remoteMissing,
      error: 'Database no longer found on GitHub - passphrase changed?');

  late final SingleFlight<SyncStatus> _flight = SingleFlight(_syncOnce);

  /// Name der geöffneten Datenbank (`databaseName(R)`), oder `null`, solange
  /// keine Sitzung offen ist. Die lokale Kopie liegt unter `ucdb_<name>`, die
  /// Remote-Datei unter `<name>.txt`; der Name ist auch der Schlüssel der
  /// Backend-Aufrufe. Wird nur von [_newSession] geleert und von
  /// [_startSession] bzw. [changeDatabasePassphrase] gesetzt.
  String? _databaseName;

  /// Die `settings.github`, aus denen [remoteBackend] der Sitzung gebaut ist.
  /// Der Sync vergleicht den Zustand der Datenbank
  /// damit statt mit einem Merge-Delta (B4b) und baut nur bei einem
  /// Unterschied ein Backend.
  GithubSettings? _backendGithub;

  /// Testnaht: baut das Backend zu `settings.github`, wenn eine Sitzung
  /// startet oder ein Merge die Einstellungen ändert. Standard:
  /// [GithubBackend] mit `<name>.txt` als Pfad. Gibt es [github] nicht
  /// (`null`, "GitHub entfernt"), ist das Ergebnis `null`.
  @visibleForTesting
  RemoteBackend? Function(GithubSettings? github, Uint8List root)?
      backendForSettings;

  RemoteBackend? _buildBackendFromSettings(
      GithubSettings? github, Uint8List root) {
    var builder = backendForSettings;
    if (builder != null) {
      return builder(github, root);
    }
    if (github == null) {
      return null;
    }
    // Der Name der Sitzung ist schon der Dateiname (`<name>.txt`, base64url
    // braucht kein Escaping).
    return GithubBackend(
        owner: github.owner,
        repo: github.repo,
        token: github.token,
        branch: github.branch);
  }

  /// Beginnt eine neue Sitzung: erhöht den Zähler (laufende Syncs der alten
  /// Sitzung verwerfen dann ihr Ergebnis) und setzt den Status. Aufzurufen,
  /// bevor [loadedDatabase] oder die Sitzungsfelder auf die neue Sitzung
  /// wechseln.
  void _newSession(SyncStatus status) {
    _session++;
    _syncEpoch++;
    (syncStatus as _SyncStatusNotifier).sawSynced = false;
    // Der Name wird danach gesetzt (siehe [_startSession]).
    _databaseName = null;
    _backendGithub = null;
    syncStatus.value = status;
    // Ein im Netz haengender Lauf der alten Sitzung darf den ersten Lauf der
    // neuen nicht aufhalten (er verwirft sein Ergebnis ohnehin).
    _flight.reset(status);
  }

  /// Speichert die geöffnete Datenbank sofort lokal (verschlüsselt unter
  /// `ucdb_<name>`) und fordert danach einen Sync an ([requestSync], ohne zu warten).
  ///
  /// Scheitert nicht am Netz: ob und wann der Remote nachzieht, zeigt nur
  /// [syncStatus]. Ein fehlendes Backend ist kein Fehler (Status `noRemote`,
  /// lokal wird trotzdem gespeichert). Wirft [RemoteBackendException], wenn
  /// gerade keine Datenbank offen ist (ohne irgendetwas anzufassen), wenn das
  /// `R` der Sitzung nicht zum Namen passt (siehe
  /// [_storeSessionCopy]; über die öffentliche API nicht auslösbar), und einen
  /// Fehler, wenn die lokale Kopie nicht geschrieben werden konnte. Gibt `true` zurück (die UI schließt ihren
  /// Dialog erst bei einem Wert).
  Future<bool> saveDatabase() async {
    await _saveLocal();
    requestSync();
    return true;
  }

  /// Der lokale Teil von [saveDatabase]: bereinigen, verschlüsseln, lokal
  /// schreiben. Kein Sync.
  Future<void> _saveLocal() async {
    // Geprueft, bevor cleanUp() die Datenbank anfasst. Bedingung ist "eine
    // Sitzung ist offen", NICHT "ein Backend ist da": ohne Backend (kein
    // GitHub konfiguriert oder per Merge entfernt) gilt lokal speichern
    // weiter, der Status ist dann `noRemote`.
    var database = loadedDatabase.value;
    var name = _databaseName;
    var key = _root;
    if (database == null || name == null || key == null) {
      throw RemoteBackendException('No writable database session');
    }
    var session = _session;
    database.cleanUp();
    // Verschluesseln und den Schreibaufruf ohne await dazwischen: die
    // Reihenfolge der lokalen Schreibvorgaenge folgt so der Reihenfolge der
    // Staende im Speicher, auch gegen einen gleichzeitig laufenden Sync.
    var data = encryptDatabase(database, key);
    await _storeSessionCopy(name, data, key);
    // Eine anstehende Aenderung ist nie "synchron", auch wenn der letzte Sync
    // sauber war (und der naechste noch nicht angelaufen oder unterdrueckt
    // ist).
    if (session == _session && syncStatus.value.state == SyncState.synced) {
      syncStatus.value = SyncStatus.notSynced;
    }
  }

  /// Schreibt die lokale Kopie der Sitzung unter `ucdb_<name>`, aber nur, wenn
  /// [key] (`R`) zu [name] gehört (sonst würde die Kopie unlesbar überschrieben):
  /// sonst Fehler, synchron geworfen, vor jedem Schreiben.
  ///
  /// Reine Vorsichtsprüfung: Name und `R` der Sitzung entstehen zusammen
  /// (`_databaseName == databaseName(_root)`), sie ist über die öffentliche
  /// API nicht auszulösen und hat keinen Test.
  Future<void> _storeSessionCopy(String name, Uint8List data, Uint8List key) {
    if (databaseName(key) != name) {
      throw RemoteBackendException(
          'The key does not match this database; nothing was saved');
    }
    return storage!.setString(localPrefsKey(name), base64.encode(data));
  }

  /// Stößt einen Sync an, ohne zu warten (für Trigger wie "Änderung
  /// gespeichert"). Fehler landen im [syncStatus], nie hier.
  ///
  /// Bei einem Rate-Limit mit bekannter Wartezeit fragt der automatische
  /// Trigger erst nach [SyncStatus.retryAt] wieder an; [syncNow] fragt
  /// immer an.
  void requestSync() {
    var status = syncStatus.value;
    var retryAt = status.retryAt;
    if (retryAt != null && DateTime.now().isBefore(retryAt)) {
      return;
    }
    // Bewusst nicht abgewartet; der Fehlerzweig faengt alles, was (entgegen
    // dem Vertrag von syncNow) doch fliegt, damit nichts unbehandelt bleibt.
    syncNow().catchError((Object _) => syncStatus.value);
  }

  /// Synct und wartet darauf. Läuft gerade ein Sync, wird er nicht
  /// unterbrochen: [syncNow] wartet auf den EINEN Folgelauf (siehe
  /// [SingleFlight]), der den Stand nach diesem Aufruf sieht. Gibt den
  /// Status am Ende zurück; wirft nie wegen des Remotes.
  Future<SyncStatus> syncNow() => _flight.run();

  Future<SyncStatus> _syncOnce() async {
    // Schnappschuss der Sitzung: nach einem await werden remoteBackend und
    // _databaseName NICHT neu gelesen, changeDatabasePassphrase/close tauschen
    // sie aus.
    var session = _session;
    var epoch = _syncEpoch;
    var database = loadedDatabase.value;
    var name = _databaseName;
    var key = _root;
    var backend = remoteBackend;
    if (database == null || name == null) {
      // Nichts offen (z. B. ein Folgelauf nach closeDatabase).
      return syncStatus.value;
    }
    bool alive() =>
        session == _session &&
        epoch == _syncEpoch &&
        identical(loadedDatabase.value, database);
    SyncStatus publish(SyncStatus status) {
      if (alive()) {
        syncStatus.value = status;
      }
      return syncStatus.value;
    }

    if (backend == null || key == null) {
      return publish(SyncStatus.noRemote);
    }
    publish(SyncStatus.syncing);
    try {
      for (var attempt = 1; attempt <= MAX_SYNC_ATTEMPTS; attempt++) {
        var remoteData = await backend.read(name);
        if (!alive()) return syncStatus.value;

        // Der normale Sync legt nie an: eine fehlende Datei ist
        // `remoteMissing`.
        if (remoteData.isEmpty) {
          return publish(_remoteMissing);
        }
        UltracipherDatabase remoteDatabase;
        try {
          remoteDatabase = _decryptRemote(remoteData, key);
        } on RemoteBackendException catch (e) {
          // KEIN Schreiben auf eine Datei, die wir nicht lesen koennen.
          return publish(SyncStatus(SyncState.notSynced, error: e.message));
        }

        // Ab hier bis zum Aufruf von _storeSessionCopy kein await.
        var before = UltracipherDatabase.fromJson(database.toJson());
        database.merge(remoteDatabase);
        var localChanged = !database.hasSameContentAs(before);
        var needsPush = !database.hasSameContentAs(remoteDatabase);
        Uint8List? data;
        if (localChanged || needsPush) {
          data = encryptDatabase(database, key);
        }
        if (data != null) {
          // Der gemergte Stand ersetzt die lokale Kopie; dieselben Bytes gehen
          // gleich ans Remote (auch ohne Merge-Aenderung: so haelt die Kopie
          // nach einem Push genau die Bytes des Remotes).
          await _storeSessionCopy(name, data, key);
          if (!alive()) return syncStatus.value;
        }

        if (needsPush) {
          try {
            await backend.write(name, data!, version: remoteData.version);
          } on RemoteConflictException {
            if (!alive()) return syncStatus.value;
            if (attempt == MAX_SYNC_ATTEMPTS) {
              return publish(const SyncStatus(SyncState.notSynced,
                  error: 'The remote changed again and again while syncing; '
                      'will retry on the next sync'));
            }
            continue;
          }
          if (!alive()) return syncStatus.value;
        }
        break;
      }

      // B4b: das Ziel wird aus dem ZUSTAND abgeleitet, nicht aus dem Delta
      // dieses Laufs. Scheiterte der Write eines frueheren Laufs nach dem
      // Merge, sieht dieser Lauf kein Delta mehr, der Zustand stimmt aber
      // noch nicht zum Backend. Nur nach normalem Ende der Schleife (die
      // Fehler- und Abbruchpfade kehren vorher zurueck).
      // Das Backend wird erst NACH dem Schreiben dieses Laufs getauscht (der
      // Stand, der gelesen und geschrieben wird, gehoert zum alten Ort).
      var switchBackend = false;
      RemoteBackend? nextBackend;
      var nextGithub = _backendGithub;
      var github = database.settings?.github;
      if (github != _backendGithub) {
        var rebuilt = _buildBackendFromSettings(github, key);
        if (_sameTarget(backend, rebuilt)) {
          // Gleiches Ziel: kein Wechsel, das ueberzaehlige neue wird
          // freigegeben.
          if (!identical(rebuilt, backend)) {
            rebuilt?.close();
          }
          _backendGithub = github;
        } else {
          switchBackend = true;
          nextBackend = rebuilt;
          nextGithub = github;
        }
      }
      if (switchBackend) {
        remoteBackend = nextBackend;
        _backendGithub = nextGithub;
        if (!identical(backend, nextBackend)) {
          backend.close();
        }
        if (nextBackend == null) {
          return publish(SyncStatus.noRemote);
        }
        // Der neue Ort wurde noch nicht gelesen: Folgelauf.
        requestSync();
      }
      // Steht ein Folgelauf an (eine Aenderung kam waehrend dieses Laufs),
      // gilt der Stand noch nicht als synchron.
      return publish(_flight.hasPending ? SyncStatus.syncing : SyncStatus.synced);
    } on RemoteAuthException catch (e) {
      return publish(SyncStatus(SyncState.authRequired,
          error: e.message, cause: e));
    } on RemoteRateLimitException catch (e) {
      var wait = e.retryAfter;
      return publish(SyncStatus(SyncState.notSynced,
          error: e.message,
          retryAfter: wait,
          retryAt: wait == null ? null : DateTime.now().add(wait),
          cause: e));
    } on RemoteBackendException catch (e) {
      // Die Meldungen der Backends enthalten nie Token oder URL.
      print('Sync failed (${e.runtimeType})');
      return publish(
          SyncStatus(SyncState.notSynced, error: e.message, cause: e));
    } catch (e) {
      // Kein e.toString(): kann URIs (Netzfehler) oder Klartext enthalten.
      print('Sync failed (${e.runtimeType})');
      return publish(SyncStatus(SyncState.notSynced,
          error: 'Sync failed (${e.runtimeType})', cause: e));
    }
  }

  /// Ob [next] dasselbe Ziel ist wie [current] (dann wird nicht getauscht).
  /// Nur zwei [GithubBackend]s mit gleichem Konto, Repo, Token und Branch
  /// sind gleich; alles andere gilt als anderes Ziel.
  static bool _sameTarget(RemoteBackend current, RemoteBackend? next) {
    if (current is GithubBackend && next is GithubBackend) {
      return current.owner == next.owner &&
          current.repo == next.repo &&
          current.token == next.token &&
          current.branch == next.branch;
    }
    return identical(current, next);
  }

  /// Mergt [csv] in die geöffnete Datenbank (es wird nichts gelöscht) und
  /// speichert sie. Gibt die Zahl der neuen Einträge plus der Einträge mit
  /// neuer Version zurück; übersprungene Zeilen (schon vorhanden) zählen nicht.
  ///
  /// Schlägt das LOKALE Speichern fehl (keine beschreibbare Sitzung, lokale
  /// nicht beschreibbar; ein fehlendes Backend allein nicht), wird der Import
  /// zurückgenommen - sonst würde der
  /// nächste Speichervorgang ihn ungefragt übernehmen. Ein Netzfehler
  /// beim anschließenden Sync ist kein Fehler dieser Methode, er zeigt sich
  /// nur im [syncStatus].
  Future<int> importCsvText(String csv) async {
    var db = loadedDatabase.value!;
    var result = importCsvInto(db, csv);
    try {
      await saveDatabase();
    } catch (_) {
      result.undo();
      rethrow;
    }
    return result.count;
  }

  /// Ob [key] ein alter `_key`-Cache-Eintrag ist: gepolstertes base64 eines
  /// 32-Byte-Digests plus `_key`. Seit Format v1 gibt es keinen Cache mehr
  /// (Spezifikation §2.4); der Erkenner bleibt, damit "Erase local data" alte
  /// Eintraege weiter entfernt. Alte Eintraege des frueheren Modells (z. B.
  /// `github_credentials_<user>_key`) passen nicht darauf.
  static bool isKeyCachePrefsKey(String key) {
    const suffix = '_key';
    if (!key.endsWith(suffix)) return false;
    var head = key.substring(0, key.length - suffix.length);
    // 32 Byte in gepolstertem base64: 44 Zeichen.
    if (head.length != 44) return false;
    try {
      return base64.decode(head).length == 32;
    } on FormatException {
      return false;
    }
  }

  /// Ob [value] (Wert eines `ucdb_*`-Eintrags) wie eine v1-Datei beginnt: die
  /// ersten 8 base64-Zeichen ergeben 6 Bytes, davon die ersten 4 muessen
  /// `UCDB` sein. Billig (keine KDF) und robust: kein String, zu kurz oder
  /// kein base64 gilt als alt. Alte Kopien (v2) beginnen mit 0x00.
  static bool isV1LocalValue(Object? value) {
    if (value is! String || value.length < 8) return false;
    try {
      return FormatV1.hasMagic(base64.decode(value.substring(0, 8)));
    } on FormatException {
      return false;
    }
  }

  bool _isLocalDatabaseKey(String key) =>
      key.startsWith(localPrefsPrefix) &&
      key.length > localPrefsPrefix.length;

  /// Ob in den Prefs Eintraege liegen, die die App nicht mehr oeffnen kann:
  /// `ucdb_*`-Kopien ohne v1-Magic (alte Formate) sowie alles, was weder
  /// `ucdb_*` noch ein alter `_key`-Cache ist (Token-Blobs, `user`, ...).
  bool get hasLegacyLocalData {
    var prefs = storage!;
    return prefs.getKeys().any((k) => _isLocalDatabaseKey(k)
        ? !isV1LocalValue(prefs.get(k))
        : !isKeyCachePrefsKey(k));
  }

  /// Ob alte lokale Datenbank-Kopien da sind (`ucdb_*` ohne v1-Magic), also
  /// Daten einer frueheren App-Version, die sich nie oeffnen lassen.
  bool get hasLegacyLocalCopies {
    var prefs = storage!;
    return prefs
        .getKeys()
        .any((k) => _isLocalDatabaseKey(k) && !isV1LocalValue(prefs.get(k)));
  }

  /// "Erase local data": beendet eine offene Sitzung und entfernt alle
  /// lokalen v1-Datenbanken (`ucdb_*` mit v1-Magic) und alle `_key`-Caches im
  /// Format von [isKeyCachePrefsKey]. Nicht gesyncte Aenderungen gehen
  /// verloren, Daten auf GitHub bleiben unberuehrt. Alles andere (alte
  /// `ucdb_*`-Kopien, Eintraege des alten Modells) bleibt, ausser mit
  /// [includeLegacy]: dann werden auch diese entfernt (Plan E5).
  Future<void> eraseLocalData({bool includeLegacy = false}) async {
    closeDatabase();
    var prefs = storage!;
    for (var key in prefs.getKeys().toList()) {
      if ((_isLocalDatabaseKey(key) && isV1LocalValue(prefs.get(key))) ||
          isKeyCachePrefsKey(key)) {
        await prefs.remove(key);
      }
    }
    if (includeLegacy) {
      await prefs.clear();
    }
  }

  /// Prefix of the preference keys that hold a local database; it lets
  /// [localDatabaseNames] find them without a passphrase.
  static const String localPrefsPrefix = 'ucdb_';

  /// Preference key of the local copy of the database called [name]
  /// (see `databaseName` in user_key_hash.dart).
  static String localPrefsKey(String name) => '$localPrefsPrefix$name';

  /// Names of all databases stored locally under [localPrefsKey] in format
  /// v1. Old copies (no `UCDB` magic, see [isV1LocalValue]) and old entries
  /// (`..._database`, token blobs, `user`, `..._key`) don't count; they only
  /// show up in [hasLegacyLocalData].
  List<String> localDatabaseNames() {
    var prefs = storage!;
    return prefs
        .getKeys()
        .where((k) => _isLocalDatabaseKey(k) && isV1LocalValue(prefs.get(k)))
        .map((k) => k.substring(localPrefsPrefix.length))
        .toList();
  }

  // Muss Random.secure() bleiben: speist die Passphrasen-Generierung
  // (generatePassphrase) mit sicherheitsrelevantem Zufall.
  static Random rnd = Random.secure();

  /// Verschlüsselt die geöffnete Datenbank wie der Remote-Speicher sie
  /// ablegt (Bytes von [encryptDatabase]). Der Aufrufer kodiert sie als base64.
  Future<Uint8List> exportEncryptedDatabase() async {
    var database = loadedDatabase.value;
    var key = _root;
    if (database == null || key == null) {
      return Future.error('No database open');
    }
    return encryptDatabase(database, key);
  }

  // --- Sitzungs-API (Plan Schritt 10) ---------------------------------------
  //
  // Eine Passphrase ist eine Datenbank: Name = databaseName(R), lokal
  // `ucdb_<name>`, remote `<name>.txt`. Die Passphrase wird überall getrimmt
  // damit Anlegen, Öffnen und Import dasselbe `R` ableiten; die Sitzung hält
  // danach nur `R`. Der normale Sync legt nie eine Remote-Datei an.
  //
  // Jede Methode leitet, prüft und entschlüsselt zuerst und wechselt erst
  // danach die Sitzung; ein Fehler lässt eine offene Sitzung unberührt.

  /// Öffnet die lokale Datenbank zu [passphrase].
  ///
  /// Wirft [NoLocalDatabaseException], wenn es unter dem Namen keine gibt
  /// (falsches Passwort eingeschlossen): dann ist nichts in die Prefs
  /// geschrieben. Wirft
  /// [LocalDatabaseUnreadableException], wenn sie existiert, aber nicht
  /// lesbar ist (Ausweg: [removeLocalDatabase] mit Passphrase).
  ///
  /// Das Backend kommt aus `settings.github` der Datenbank; ohne Einstellung
  /// bleibt der Status `noRemote` und lokal speichern geht trotzdem. Mit
  /// Backend läuft der erste Sync gleich im Hintergrund an.
  Future<void> openLocalDatabase(String passphrase) async {
    var key = await deriveRoot(passphrase);
    var name = databaseName(key);
    // Lesen und Sitzung starten ohne await dazwischen: eine noch offene
    // Sitzung derselben Datenbank (Save/Sync) kann sonst zwischen Lesen und
    // Start ihren neueren Stand schreiben, den wir dann ueberschreiben.
    var database = _readNamedLocal(name, key);
    if (database == null) {
      throw NoLocalDatabaseException();
    }
    _startSession(name, key, database);
  }

  /// Legt eine neue, leere Datenbank zu [passphrase] an und öffnet sie.
  ///
  /// Gibt es lokal schon eine unter diesem Namen, wirft die Methode
  /// [LocalDatabaseExistsException] und ändert nichts (überschreiben gibt es
  /// nicht, auch keine unlesbare Kopie). Der Status ist `noRemote`; GitHub
  /// einzurichten ist ein eigener Schritt.
  Future<void> createDatabase(String passphrase) async {
    var key = await deriveRoot(passphrase);
    var name = databaseName(key);
    if (storage!.containsKey(localPrefsKey(name))) {
      throw LocalDatabaseExistsException();
    }
    var database = UltracipherDatabase();
    await _writeNamedLocal(name, database, key);
    _startSession(name, key, database);
  }

  /// Öffnet eine als base64-Text exportierte Datenbank ([exportEncryptedDatabase])
  /// als lokale Datenbank.
  ///
  /// Whitespace im Text wird entfernt. Schlechter Text oder falsche
  /// Passphrase ergeben dieselbe neutrale Fehlermeldung (ohne Inhalt). Gibt es
  /// unter dem Namen schon eine lokale Datenbank, wird der Import hineingemergt
  /// (die lokale Kopie ist dann Empfänger); ist sie nicht lesbar, bricht der
  /// Import ab, ohne sie zu überschreiben. Danach ist die Datenbank lokal
  /// gespeichert und offen. Enthält sie GitHub-Einstellungen, startet sofort
  /// ein Sync; fehlt die Remote-Datei, ist der Status `remoteMissing` (kein
  /// Anlegen).
  Future<void> importEncryptedText(String base64Text, String passphrase) async {
    // Grobe Grenze vor dem Entfernen der Leerzeichen (kein Kopieren eines
    // riesigen Texts), dann die genaue vor dem Dekodieren (> ca. 89,5 M
    // Zeichen).
    if (base64Text.length > 2 * maxBase64Length) {
      return Future.error(importFailedMessage);
    }
    Uint8List bytes;
    try {
      bytes = decodeBase64Bounded(base64Text.replaceAll(RegExp(r'\s'), ''));
      // Der Kopf ist oeffentlich: ein altes Format (v2) oder eine neuere
      // Version wird vor der teuren Ableitung erkannt und klar gemeldet. Die
      // Meldung haengt nicht von der Passphrase ab.
      FormatV1.parseHeader(bytes);
    } on UltracipherFormatException catch (e) {
      return Future.error(_formatErrorMessage(e));
    } on UltracipherAuthenticationException {
      return Future.error(importFailedMessage);
    } on FormatException {
      // Ohne Details: die Originalmeldung kann Teile des Texts enthalten.
      return Future.error(importFailedMessage);
    }
    var key = await deriveRoot(passphrase);
    UltracipherDatabase imported;
    try {
      imported = decryptDatabase(bytes, key);
    } catch (_) {
      // Kein e.toString(): ein JSON-Fehler enthält einen Ausschnitt des
      // Klartexts; und kein Unterschied zwischen "falsche Passphrase" und
      // "kein Export".
      return Future.error(importFailedMessage);
    }
    var name = databaseName(key);
    // Kein await mehr zwischen Lesen der lokalen Kopie und Sitzungsstart
    // (siehe [openLocalDatabase]).
    var database = _readNamedLocal(name, key);
    if (database == null) {
      database = imported;
    } else {
      database.merge(imported);
    }
    // setString aktualisiert den Cache der Prefs sofort; erst nach dem
    // Sitzungsstart wird auf das Schreiben gewartet.
    var written = _writeNamedLocal(name, database, key);
    _startSession(name, key, database);
    try {
      await written;
    } catch (_) {
      // Nicht gespeichert: keine Sitzung, die ihren Stand fuer gesichert haelt.
      closeDatabase();
      rethrow;
    }
  }

  /// Meldung für einen nicht importierbaren Text (kein base64, kein Export,
  /// falsche Passphrase), bewusst ohne Unterscheidung.
  static const String importFailedMessage =
      'Wrong passphrase or not an Ultracipher export';

  /// Meldung für ein erkennbar altes Format (Magic ungleich `UCDB`, z. B. v2).
  /// Es gibt keinen Leser dafür; Altdaten kommen nur per CSV (Spezifikation E9).
  static const String oldFormatMessage =
      'This is not an Ultracipher v1 database (older app versions used a '
      'different format). Export a CSV in the old app and import it here.';

  /// Meldung für eine Datei einer neueren Formatversion oder Suite.
  static const String newerVersionMessage =
      'This file was written by a newer version of the app; please update.';

  /// Feste Meldung zu einem Formatfehler im Kopf (nie mit Dateiinhalt).
  static String _formatErrorMessage(UltracipherFormatException e) {
    switch (e.kind) {
      case FormatErrorKind.badMagic:
        return oldFormatMessage;
      case FormatErrorKind.unsupportedVersion:
      case FormatErrorKind.unsupportedSuite:
      case FormatErrorKind.unsupportedFlags:
        return newerVersionMessage;
      case FormatErrorKind.unsupportedKdfProfile:
        return 'This file belongs to a different key profile; '
            'please update the app.';
      case FormatErrorKind.tooLarge:
        return 'The database file is too large';
    }
  }

  /// Entfernt eine lokale Datenbank und schließt die Sitzung, falls es die
  /// offene war. Gibt zurück, ob eine lokale Kopie da war. Die Remote-Datei
  /// bleibt unberührt. Alte `_key`-Einträge fasst sie nicht an (nur
  /// [eraseLocalData]).
  ///
  /// Ohne [passphrase]: die offene Datenbank (Fehler, wenn keine offen ist).
  ///
  /// Mit [passphrase] (R2, Ausweg aus einer nicht lesbaren Kopie): ohne
  /// offene Sitzung und OHNE die Datenbank je zu entschlüsseln. Es braucht
  /// nur den Namen, dafür läuft die volle Ableitung von `R`. Ein falsches
  /// Passwort findet nichts und ändert nichts (Rückgabe `false`).
  ///
  /// Die Sitzung wird zuerst beendet (ein laufender Sync verwirft damit sein
  /// Ergebnis und schreibt die Kopie nicht neu), danach werden die Einträge
  /// entfernt. Die UI fragt vorher selbst nach und versucht bei Bedarf erst
  /// einen Sync ([hasUnsyncedChanges]).
  Future<bool> removeLocalDatabase({String? passphrase}) async {
    String name;
    if (passphrase == null) {
      var current = _databaseName;
      if (current == null) {
        return Future.error('No database open');
      }
      name = current;
    } else {
      name = databaseName(await deriveRoot(passphrase));
    }
    // Zuerst die Sitzung beenden, dann die Einträge entfernen.
    if (_databaseName == name) {
      closeDatabase();
    }
    var prefsKey = localPrefsKey(name);
    var existed = storage!.containsKey(prefsKey);
    await storage!.remove(prefsKey);
    return existed;
  }

  /// Ob die offene Datenbank Änderungen hat, die nur auf diesem Gerät sind:
  /// `SyncState != synced` der laufenden Sitzung (Plan §3.3). Das schließt
  /// `noRemote` ein (die lokale Kopie ist dann die einzige) und `syncing` /
  /// den Zustand vor dem ersten abgeschlossenen Sync ("unbekannt"); die UI
  /// unterscheidet über [syncStatus]. Ohne offene Datenbank `false`.
  bool get hasUnsyncedChanges =>
      loadedDatabase.value != null &&
      syncStatus.value.state != SyncState.synced;

  // --- GitHub-Einstellungen der Sitzung (Plan Schritt 11) -------------------

  /// Zeitstempel für eine ausdrückliche Änderung der Einstellungen: jetzt
  /// (UTC), aber nie vor oder gleich dem Stand in [db]. Eine Änderung
  /// gewinnt im LWW-Merge so auch gegen Einstellungen eines Geräts, dessen
  /// Uhr vorgeht.
  DateTime _settingsTime(UltracipherDatabase db) {
    var now = DateTime.now().toUtc();
    var current = db.settings?.time;
    if (current != null && !now.isAfter(current)) {
      return current.add(const Duration(milliseconds: 1));
    }
    return now;
  }

  /// Wechselt in der laufenden Sitzung das Backend. Ein noch laufender Sync
  /// des alten verwirft sein Ergebnis ([_syncEpoch]) und kann das neue Backend
  /// nicht überschreiben; die Sitzung selbst bleibt dieselbe ([_session]),
  /// ein laufendes Speichern gilt weiter. Gibt das alte Backend zurück; der
  /// Aufrufer schließt es, wenn er es nicht mehr braucht.
  RemoteBackend? _replaceBackend(
      RemoteBackend? next, GithubSettings? github, SyncStatus status) {
    var old = remoteBackend;
    _syncEpoch++;
    syncStatus.value = status;
    _flight.reset(status);
    remoteBackend = next;
    _backendGithub = github;
    return old;
  }

  /// Richtet GitHub für die offene Datenbank (neues Modell) ein oder ändert
  /// es: [token] (Pflicht), [repo] (Standard `ultracipher-data`), [branch]
  /// (leer oder nur Leerraum: `''`, gemeint ist der Standard-Branch des
  /// Repositorys, egal ob `main` oder `master`).
  ///
  /// Ablauf: Konto per [GithubBackend.resolveOwner] ermitteln, `<name>.txt`
  /// am Ziel lesen.
  /// - Datei da: der Remote wird hineingemergt (neues Gerät), ist der Stand
  ///   danach verschieden, wird zurückgeschrieben.
  /// - Datei fehlt: angelegt wird nur bei der Erstkonfiguration (vorher kein
  ///   `settings.github`) oder nach einem Wechsel von Konto, Repo oder
  ///   Branch, sonst mit [confirmCreate]. Sonst wirft die Methode
  ///   [GithubFileMissingException] (E3: Token-Neueingabe in `remoteMissing`
  ///   legt nicht still neu an).
  ///
  /// Alles Netz läuft VOR jeder Änderung am Zustand, auf einer Kopie der
  /// Datenbank. Erst wenn das Ziel den Stand hat, wird er übernommen:
  /// Einstellungen mit neuer `time` (LWW), Backend getauscht, lokal
  /// gespeichert. Auth-, Netz- und Konfliktfehler (und eine nicht lesbare
  /// Remote-Datei) werfen daher mit unverändertem Zustand; einen Netzfehler
  /// wiederholt der Aufrufer. Konto-, Repo- oder Branch-Wechsel (E1): danach
  /// wird der gemergte Stand, mit den neuen Einstellungen, einmal an den
  /// ALTEN Ort geschrieben (Weiterleitung für andere Geräte; die Datei bleibt
  /// stehen). Scheitert das, ist der Wechsel trotzdem gelungen
  /// ([GithubSettingsResult.oldLocationError]).
  ///
  /// [httpClient] ist die Testnaht für `resolveOwner`; das Backend entsteht
  /// über [_buildBackendFromSettings].
  Future<GithubSettingsResult> configureGithub(
      {required String token,
      String? repo,
      String? branch,
      bool confirmCreate = false,
      http.Client? httpClient}) async {
    var database = loadedDatabase.value;
    var name = _databaseName;
    var key = _root;
    if (database == null || name == null || key == null) {
      return Future.error('No database open');
    }
    var newToken = token.trim();
    if (newToken.isEmpty) {
      return Future.error('Enter a GitHub token');
    }
    String orDefault(String? value, String fallback) =>
        value == null || value.trim().isEmpty ? fallback : value.trim();
    var newRepo = orDefault(repo, GithubBackend.defaultRepo);
    var newBranch = orDefault(branch, '');

    var session = _session;
    bool alive() =>
        session == _session && identical(loadedDatabase.value, database);
    void requireAlive() {
      if (!alive()) {
        throw RemoteBackendException('The database was closed meanwhile; '
            'GitHub settings were not changed');
      }
    }

    var owner = await GithubBackend.resolveOwner(newToken, client: httpClient);
    requireAlive();
    var newGithub = GithubSettings(
        token: newToken, owner: owner, repo: newRepo, branch: newBranch);
    var newBackend = _buildBackendFromSettings(newGithub, key)!;

    // Ab hier: Kopie. Die offene Datenbank bleibt unberuehrt, bis das Ziel
    // den Stand hat.
    var candidate = UltracipherDatabase.fromJson(database.toJson());
    var previous = database.settings?.github;
    // Ein Wechsel des Kontos (anderes Token, anderer Besitzer) zaehlt wie ein
    // Wechsel von Repo oder Branch: anlegen ohne Rueckfrage und
    // Weiterleitung (bewusst so entschieden).
    var moved = previous != null &&
        (previous.owner != owner ||
            previous.repo != newRepo ||
            previous.branch != newBranch);
    // Aendert sich nur der Branch und ist eine Seite leer (Standard-Branch),
    // kann es dieselbe Datei sein (Standard-Branch = der benannte): dann ist
    // ein Wechsel keine Erlaubnis zum stillen Neuanlegen (E3). Die
    // Weiterleitung bleibt, der Merge dort ist verlustfrei.
    var maybeSameFile = previous != null &&
        moved &&
        previous.owner == owner &&
        previous.repo == newRepo &&
        (previous.branch.isEmpty || newBranch.isEmpty);
    var created = false;
    try {
      var remote = await newBackend.read(name);
      requireAlive();
      UltracipherDatabase? remoteDatabase;
      if (remote.isEmpty) {
        if (!(confirmCreate ||
            previous == null ||
            (moved && !maybeSameFile))) {
          throw GithubFileMissingException();
        }
        created = true;
      } else {
        // Wirft bei einer nicht lesbaren Datei: kein Schreiben darauf.
        remoteDatabase = _decryptRemote(remote, key);
        candidate.merge(remoteDatabase);
      }
      if (candidate.settings?.github != newGithub) {
        candidate.setSettings(
            github: newGithub, time: _settingsTime(candidate));
      }
      if (created ||
          remoteDatabase == null ||
          !candidate.hasSameContentAs(remoteDatabase)) {
        await newBackend.write(name, encryptDatabase(candidate, key),
            version: remote.version);
        requireAlive();
      }

      // Uebernehmen, ohne await bis zum Wechsel der Sitzung. Der Merge ist ein
      // Halbverband: Aenderungen der Zwischenzeit gehen nicht verloren.
      var oldBackend = remoteBackend;
      database.merge(candidate);
      var stored =
          _storeSessionCopy(name, encryptDatabase(database, key), key);
      _replaceBackend(
          newBackend,
          newGithub,
          database.hasSameContentAs(candidate)
              ? SyncStatus.synced
              : SyncStatus.notSynced);
      try {
        await stored;
      } catch (_) {
        // Ziel und Arbeitsspeicher haben den neuen Stand, die lokale Kopie
        // nicht: ungesichert, bis das naechste Speichern gelingt.
        if (!identical(oldBackend, newBackend)) oldBackend?.close();
        if (alive()) syncStatus.value = SyncStatus.notSynced;
        rethrow;
      }

      // Das alte Backend wird nur fuer die Weiterleitung noch gebraucht.
      Exception? oldLocationError;
      if (moved && oldBackend != null) {
        oldLocationError = await _forwardToOldLocation(
            oldBackend, name, key, database, alive);
      }
      if (!identical(oldBackend, newBackend)) oldBackend?.close();
      if (alive()) {
        if (!database.hasSameContentAs(candidate)) {
          // Etwas kam hinzu (Aenderung waehrend des Vorgangs, Stand des alten
          // Orts): das neue Ziel hat es noch nicht.
          syncStatus.value = SyncStatus.notSynced;
          requestSync();
        }
      }
      return GithubSettingsResult(
          created: created, oldLocationError: oldLocationError);
    } catch (_) {
      // Das neue Backend wurde nicht uebernommen (sonst kaeme der Fehler nach
      // dem Wechsel nur vom lokalen Speichern; dann ist es das aktive).
      if (!identical(remoteBackend, newBackend)) newBackend.close();
      rethrow;
    }
  }

  /// E1: schreibt den Stand von [database] (mit den neuen Einstellungen)
  /// einmal an den alten Ort, über [old]. Liest dafür zuerst (Version) und
  /// mergt den Stand dort hinein und lokal, damit nichts verloren geht; bei
  /// einem Konflikt neu lesen, mergen, schreiben (wie [_syncOnce], höchstens
  /// [MAX_SYNC_ATTEMPTS]). Gibt den Fehler zurück statt ihn zu werfen; gibt
  /// es die Datei dort nicht (mehr), ist nichts weiterzuleiten.
  Future<Exception?> _forwardToOldLocation(
      RemoteBackend old,
      String name,
      Uint8List key,
      UltracipherDatabase database,
      bool Function() alive) async {
    try {
      Exception? conflict;
      for (var attempt = 1; attempt <= MAX_SYNC_ATTEMPTS; attempt++) {
        var remote = await old.read(name);
        if (!alive() || remote.isEmpty) return null;
        database.merge(decryptDatabase(remote.bytes, key));
        var data = encryptDatabase(database, key);
        await _storeSessionCopy(name, data, key);
        if (!alive()) return null;
        try {
          await old.write(name, data, version: remote.version);
          return null;
        } on RemoteConflictException catch (e) {
          conflict = e;
        }
      }
      return conflict;
    } catch (e) {
      print('Writing to the old GitHub location failed (${e.runtimeType})');
      return e is Exception
          ? e
          : RemoteBackendException('Write failed (${e.runtimeType})');
    }
  }

  /// Entfernt GitHub aus der offenen Datenbank (neues Modell): `github: null`
  /// mit neuer `time` (explizit, ein Fehlen genügt dem Merge nicht), lokal
  /// gespeichert, Backend verworfen, Status `noRemote`. Andere Geräte
  /// erfahren es durch den Merge der Remote-Datei (sie wechseln dann auch auf
  /// `noRemote`, B4a).
  ///
  /// Damit sie es erfahren, läuft vorher der normale Sync mit `github: null`
  /// (er schreibt an den alten Ort und wechselt dann selbst auf kein Backend,
  /// B4b). Das ist best effort: scheitert er (offline, Token abgelehnt, Datei
  /// fehlt), wird GitHub trotzdem lokal entfernt (sonst käme man mit einem
  /// widerrufenen Token nie heraus) und [GithubSettingsResult.oldLocationError]
  /// meldet, dass es nicht weitergegeben wurde. Die Remote-Datei bleibt immer
  /// stehen.
  ///
  /// Einstellungen und Backend stimmen am Ende immer überein. Brachte der
  /// Sync neuere Einstellungen eines Geräts mit vorgehender Uhr mit (GitHub
  /// ist wieder gesetzt), wird mit der gemergten Zeit erneut entfernt; nach
  /// drei Runden gibt die Methode mit einem Fehler auf, ohne das Backend zu
  /// verwerfen. Gespeichert wird vor der Änderung im Speicher: scheitert das
  /// lokale Speichern, bleibt alles wie es war.
  Future<GithubSettingsResult> removeGithub() async {
    var database = loadedDatabase.value;
    var name = _databaseName;
    var key = _root;
    if (database == null || name == null || key == null) {
      return Future.error('No database open');
    }
    if (database.settings?.github == null && remoteBackend == null) {
      return GithubSettingsResult();
    }
    var session = _session;
    bool alive() =>
        session == _session && identical(loadedDatabase.value, database);
    for (var round = 1; round <= 3; round++) {
      // Auf einer Kopie speichern, erst danach die offene Datenbank aendern.
      var candidate = UltracipherDatabase.fromJson(database.toJson());
      candidate.setSettings(github: null, time: _settingsTime(candidate));
      await _storeSessionCopy(name, encryptDatabase(candidate, key), key);
      if (!alive()) return GithubSettingsResult();
      database.merge(candidate);

      var status = await syncNow();
      // Kam waehrenddessen ein weiterer Trigger, steht der Status noch auf
      // syncing: auf dessen Ende warten.
      while (status.state == SyncState.syncing) {
        status = await syncNow();
      }
      if (!alive()) return GithubSettingsResult();
      if (database.settings?.github != null) {
        // Der Sync-Merge brachte neuere Einstellungen mit: mit der jetzt
        // gemergten Zeit noch einmal.
        continue;
      }
      if (remoteBackend == null) {
        return GithubSettingsResult();
      }
      // Der Sync hat das Backend nicht selbst verworfen (er scheiterte):
      // Einstellungen sagen "kein GitHub", also auch die Sitzung.
      _replaceBackend(null, null, SyncStatus.noRemote)?.close();
      var cause = status.cause;
      return GithubSettingsResult(
          oldLocationError: cause is Exception
              ? cause
              : RemoteBackendException(
                  status.error ?? 'The sync did not finish (${status.state})'));
    }
    throw RemoteBackendException('GitHub could not be removed: the settings '
        'kept coming back from the remote; try again');
  }

  // --- Passwortwechsel (Plan Schritt 12, §3.5) --------------

  /// Höchstens so lange wartet [changeDatabasePassphrase] auf frühere
  /// Schreibaufrufe, die noch unterwegs sind (R3). Testnaht. Mit
  /// [GithubBackend] ist das nur ein Sicherheitsnetz: dessen requestTimeout
  /// (30 s) bricht Anfragen ab und erledigt sie vorher.
  @visibleForTesting
  Duration pendingWriteWait = const Duration(seconds: 60);

  /// Wechselt die Passphrase der offenen Datenbank (neues Modell). Neue
  /// Passphrase heißt neuer Name: die Datenbank zieht nach `<neuer Name>`
  /// um, der alte Name wird danach entfernt.
  ///
  /// - Lokal-only (kein `settings.github`): unter dem neuen Namen speichern,
  ///   dann die alte Kopie entfernen.
  /// - Mit GitHub ist Netz Pflicht (E2): (1) alte und neue Datei lesen; gibt
  ///   es die neue schon, wird sie gemergt (gleiche Passphrase heißt dieselbe
  ///   Datenbank), sonst angelegt; (2) neu schreiben, erst remote, dann
  ///   lokal; (3) alte Datei mit ihrer Version löschen (fehlt sie, ist das
  ///   recht); (4) alte lokale Kopie entfernen.
  ///
  /// Scheitert etwas vor dem Ende von (2) (offline, Token abgelehnt,
  /// Konflikt, nicht lesbare Datei), wirft die Methode und die Sitzung bleibt
  /// unter der alten Passphrase. Nach (2) läuft die Sitzung unter der neuen;
  /// scheitert (3) oder (4), meldet das [PassphraseChangeResult.cleanupError]
  /// und die alten Kopien bleiben stehen. In jedem Fall bleiben beide Namen
  /// lesbar, es geht nichts verloren.
  ///
  /// Gibt es lokal schon eine Datenbank unter dem neuen Namen, wirft die
  /// Methode [LocalDatabaseExistsException] (ohne Änderung); mit
  /// [mergeLocal] wird sie hineingemergt.
  ///
  /// Ein anderes Gerät sieht danach `remoteMissing`; sein Ausweg ist derselbe
  /// Wechsel auf die neue Passphrase, der seine Änderungen in die neue Datei
  /// mergt.
  ///
  /// Die Sitzung hält keine Passphrase (E6): [oldPassphrase] wird neu
  /// abgeleitet und konstantzeitig mit `R` der Sitzung verglichen. Das kostet
  /// je eine KDF für das alte und das neue Passwort.
  ///
  /// Läuft unter der Sperre des Syncs: kein Sync des alten Namens kann
  /// dazwischen schreiben. Nicht gleichzeitig mit [configureGithub] oder
  /// [removeGithub] aufrufen (die UI ist modal).
  Future<PassphraseChangeResult> changeDatabasePassphrase(
      {required String oldPassphrase,
      required String newPassphrase,
      bool mergeLocal = false}) async {
    var database = loadedDatabase.value;
    var oldName = _databaseName;
    var oldKey = _root;
    if (database == null || oldName == null || oldKey == null) {
      return Future.error('No database open');
    }
    var newPass = newPassphrase.trim();
    if (newPass.isEmpty) {
      return Future.error('Enter a new passphrase');
    }
    var session = _session;
    var backend = remoteBackend;
    bool alive() =>
        session == _session &&
        identical(loadedDatabase.value, database) &&
        identical(remoteBackend, backend);
    void requireAlive() {
      if (!alive()) {
        throw RemoteBackendException('The database was closed or changed '
            'meanwhile; the passphrase was not changed');
      }
    }

    // B6: alles Teure VOR der Sperre (die Ableitung dauert Sekunden); unter
    // der Sperre folgt nur noch Netz und Speichern.
    // E6: das alte Passwort wird gegen `R` der Sitzung geprueft.
    var checkedOld = await deriveRoot(oldPassphrase);
    if (constantTimeDiff(checkedOld, oldKey) != 0) {
      return Future.error('Invalid old passphrase');
    }
    var newKey = await deriveRoot(newPass);
    if (constantTimeDiff(newKey, oldKey) == 0) {
      return Future.error('The new passphrase is the same as the old one');
    }
    requireAlive();
    var newName = databaseName(newKey);
    // Frueh melden, vor jedem Netz; unter der Sperre noch einmal.
    _localTargetOf(newName, newKey, mergeLocal);

    return _flight.exclusive(() async {
      requireAlive();
      var localTarget = _localTargetOf(newName, newKey, mergeLocal);
      var github = database.settings?.github;
      if (github != null && backend == null) {
        throw RemoteBackendException('GitHub is configured but not connected; '
            'the passphrase was not changed');
      }
      var remote = github != null;

      // Auf einer Kopie, bis beide neuen Kopien geschrieben sind.
      var candidate = UltracipherDatabase.fromJson(database.toJson());
      if (localTarget != null) {
        candidate.merge(localTarget);
      }
      var oldData = RemoteData(bytes: Uint8List(0));
      String? newVersion;
      Uint8List data;
      if (remote) {
        // R3: ein Schreibaufruf, den der Timeout aufgegeben hat, kann noch
        // ankommen. Erst wenn keiner mehr unterwegs ist, wird die alte Datei
        // gelesen; ihre Version deckt dann alles ab, was je ankommen kann.
        try {
          await backend!.whenWritesSettled().timeout(pendingWriteWait);
        } on TimeoutException {
          throw RemoteBackendException('An earlier request to GitHub has not '
              'finished yet; the passphrase was not changed. Check the '
              'network and try again in a minute.');
        }
        requireAlive();
        oldData = await backend.read(oldName);
        requireAlive();
        var newData = await backend.read(newName);
        requireAlive();
        if (!oldData.isEmpty) {
          candidate.merge(_decryptRemote(oldData, oldKey));
        }
        if (!newData.isEmpty) {
          candidate.merge(_decryptRemote(newData, newKey));
        }
        data = encryptDatabase(candidate, newKey);
        newVersion =
            await backend.write(newName, data, version: newData.version);
        requireAlive();
      } else {
        data = encryptDatabase(candidate, newKey);
      }
      await storage!.setString(localPrefsKey(newName), base64.encode(data));
      requireAlive();

      // Wechsel der Sitzung ohne await. Kein _newSession: das gaebe die Sperre
      // frei. Der neue Zaehler laesst ein laufendes Speichern des alten Namens
      // scheitern, statt dessen Kopie neu anzulegen; Aenderungen aus der
      // Zwischenzeit bleiben im Speicher und werden unten gesichert.
      database.merge(candidate);
      _session++;
      _syncEpoch++;
      session = _session;
      _databaseName = newName;
      _root = newKey;
      var pushed = candidate;
      syncStatus.value = !remote
          ? SyncStatus.noRemote
          : database.hasSameContentAs(pushed)
              ? SyncStatus.synced
              : SyncStatus.notSynced;

      Exception? cleanupError;
      try {
        if (!database.hasSameContentAs(candidate)) {
          await _storeSessionCopy(
              newName, encryptDatabase(database, newKey), newKey);
        }
        if (remote && !oldData.isEmpty) {
          pushed = await _deleteOldRemote(backend!, oldName, oldData, oldKey,
                  newName, newKey, newVersion, database, alive) ??
              pushed;
        }
        // Erst wenn die alte Datei weg ist: sonst bleibt der alte Name ganz
        // lesbar und der Wechsel von dort wiederholbar.
        await storage!.remove(localPrefsKey(oldName));
      } catch (e) {
        print('Passphrase changed, but the old copy was not removed '
            '(${e.runtimeType})');
        cleanupError = e is Exception
            ? e
            : RemoteBackendException('Cleanup failed (${e.runtimeType})');
      }
      if (remote && alive() && !database.hasSameContentAs(pushed)) {
        // Aenderungen aus der Zwischenzeit: der Sync nach der Sperre bringt
        // sie zur neuen Datei.
        syncStatus.value = SyncStatus.notSynced;
        requestSync();
      }
      return PassphraseChangeResult(cleanupError: cleanupError);
    });
  }

  /// Die lokale Kopie unter [newName], die ein Passwortwechsel hineinmergen
  /// soll, oder `null`. Ohne [mergeLocal] ist ein Treffer das Signal an die
  /// UI; eine unlesbare Kopie ist immer ein Fehler (sie wird nicht
  /// überschrieben).
  UltracipherDatabase? _localTargetOf(
      String newName, Uint8List newKey, bool mergeLocal) {
    if (!storage!.containsKey(localPrefsKey(newName))) return null;
    if (!mergeLocal) throw LocalDatabaseExistsException();
    return _readNamedLocal(newName, newKey);
  }

  /// Entschlüsselt eine Remote-Datei; wirft sonst eine
  /// [RemoteBackendException], deren Meldung nur den Fehlertyp nennt.
  static UltracipherDatabase _decryptRemote(RemoteData data, Uint8List key) {
    try {
      return decryptDatabase(data.bytes, key);
    } on UltracipherFormatException catch (e) {
      // Fester Text, ohne Dateiinhalt (z. B. altes Format).
      throw RemoteBackendException(_formatErrorMessage(e));
    } catch (e) {
      // Kein e.toString(): ein JSON-Fehler enthaelt einen Ausschnitt des
      // Klartexts.
      print('Wrong passphrase or corrupted data (${e.runtimeType})');
      throw RemoteBackendException('Wrong passphrase or corrupted data in the '
          'remote file (${e.runtimeType})');
    }
  }

  /// Schritt 3 des Passwortwechsels: die alte Datei in der gelesenen Version
  /// löschen. Ein Konflikt heißt: sie fehlt schon (GitHubs 404, erledigt)
  /// oder ein anderes Gerät hat inzwischen geschrieben. Dann neu lesen; ist
  /// sie da, ihren Stand in [database] mergen, die neue Datei (remote, dann
  /// lokal) neu schreiben und erneut löschen, höchstens [MAX_SYNC_ATTEMPTS]
  /// Mal. Gibt den zuletzt geschriebenen Stand zurück (oder `null`, wenn
  /// nichts neu geschrieben wurde); wirft, wenn die Datei nicht weg ist.
  Future<UltracipherDatabase?> _deleteOldRemote(
      RemoteBackend backend,
      String oldName,
      RemoteData oldData,
      Uint8List oldKey,
      String newName,
      Uint8List newKey,
      String? newVersion,
      UltracipherDatabase database,
      bool Function() alive) async {
    void requireAlive() {
      if (!alive()) {
        throw RemoteBackendException('The database was closed before the old '
            'copy was removed');
      }
    }

    UltracipherDatabase? pushed;
    var version = oldData.version!;
    for (var attempt = 1; attempt <= MAX_SYNC_ATTEMPTS; attempt++) {
      try {
        await backend.delete(oldName, version);
        return pushed;
      } on RemoteConflictException {
        requireAlive();
      }
      var again = await backend.read(oldName);
      requireAlive();
      if (again.isEmpty) {
        return pushed;
      }
      // Mergen, verschluesseln und den Cache-Aufruf ohne await dazwischen,
      // lokal VOR dem Remote (wie _syncOnce): ein Speichern waehrend des
      // Schreibens landet danach in der Kopie und wird nicht von diesem
      // aelteren Stand ueberschrieben.
      database.merge(_decryptRemote(again, oldKey));
      var snapshot = UltracipherDatabase.fromJson(database.toJson());
      var data = encryptDatabase(database, newKey);
      await _storeSessionCopy(newName, data, newKey);
      requireAlive();
      newVersion = await backend.write(newName, data, version: newVersion);
      requireAlive();
      pushed = snapshot;
      version = again.version!;
    }
    throw RemoteConflictException('The old file kept changing while it was '
        'being removed');
  }

  /// Die entschlüsselte lokale Kopie unter [name] oder `null`, wenn es keine
  /// gibt. Eine unlesbare Kopie ist ein Fehler, nie "keine": sie darf nicht
  /// überschrieben werden.
  UltracipherDatabase? _readNamedLocal(String name, Uint8List key) {
    var text = storage!.getString(localPrefsKey(name));
    if (text == null) return null;
    try {
      return decryptDatabase(decodeBase64Bounded(text), key);
    } on UltracipherFormatException catch (e) {
      print('Local copy has an unsupported format (${e.kind})');
      throw LocalDatabaseUnreadableException(_formatErrorMessage(e));
    } catch (e) {
      print('Failed to decrypt/parse the local copy (${e.runtimeType})');
      throw LocalDatabaseUnreadableException('${e.runtimeType}');
    }
  }

  Future<void> _writeNamedLocal(
      String name, UltracipherDatabase database, Uint8List key) {
    return storage!.setString(
        localPrefsKey(name), base64.encode(encryptDatabase(database, key)));
  }

  /// Beginnt die Sitzung für [database]. Das Backend kommt aus
  /// deren `settings.github` (siehe [_buildBackendFromSettings]); ohne eines
  /// ist der Status `noRemote`, sonst `notSynced` (noch kein Sync
  /// abgeschlossen) und der erste Sync läuft an.
  void _startSession(
      String name, Uint8List key, UltracipherDatabase database) {
    _newSession(SyncStatus.noRemote);
    _databaseName = name;
    var github = database.settings?.github;
    var backend = github == null ? null : _buildBackendFromSettings(github, key);
    if (backend != null) {
      syncStatus.value = SyncStatus.notSynced;
    }
    _root = key;
    remoteBackend = backend;
    _backendGithub = backend == null ? null : github;
    loadedDatabase.value = database;
    if (backend != null) {
      requestSync();
    }
  }

  void closeDatabase() {
    // Zuerst die Sitzung beenden: ein noch laufender Sync verwirft damit sein
    // Ergebnis (keine lokale Kopie, kein loadedDatabase, kein Status).
    _newSession(SyncStatus.noRemote);
    loadedDatabase.value = null;
    _root = null;
    // Otherwise remoteBackend would stay whatever the closed session left it
    // as (a GithubBackend, still holding that session's token) and leak into
    // the next session on this app run.
    remoteBackend = null;
  }

  /// Entschlüsselt eine Datei von Format v1 mit `R` ([root], 64 B). Fehler
  /// siehe [decryptDatabaseV1].
  static UltracipherDatabase decryptDatabase(Uint8List bytes, Uint8List root) =>
      decryptDatabaseV1(bytes, root);

  /// Verschlüsselt [database] als Datei v1 mit `R` ([root]). [fileSalt] ist
  /// nur für Tests; sonst kommt er bei jedem Aufruf frisch aus `Random.secure()`.
  static Uint8List encryptDatabase(UltracipherDatabase database, Uint8List root,
          {Uint8List? fileSalt}) =>
      encryptDatabaseV1(database, root, fileSalt: fileSalt);
}
