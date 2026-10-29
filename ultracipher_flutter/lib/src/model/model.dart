import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:collection/collection.dart';
import 'package:csv/csv.dart';
import 'package:ultracipher_flutter/src/model/extensions.dart';
import 'package:uuid/uuid.dart';

Iterable<String> findStringsRecursive(dynamic input) sync* {
  if (input is String) {
    yield input;
    return;
  }
  if (input is List) {
    for (var i in input) {
      yield* findStringsRecursive(i);
    }
    return;
  }
  if (input is Map) {
    for (var i in input.values) {
      yield* findStringsRecursive(i);
    }
  }
  return;
}

class UltracipherDatabase {
  static const String ENTRIES = 'entries';

  // CSV-Spalten: id, create date, name, tags, body. Die Form ohne id ist die
  // alte (nur noch lesbar, siehe [importFromCsv]).
  static const List<String> CSV_HEADER = [
    'id',
    'create date',
    'name',
    'tags',
    'body'
  ];
  static const List<String> CSV_HEADER_WITHOUT_ID = [
    'create date',
    'name',
    'tags',
    'body'
  ];

//  static const String META = 'meta';

  // Loeschliste: id -> Zeitpunkt der Loeschung (immer UTC).
  static const String DELETED = 'deleted';
  static const String DELETED_ID = 'id';
  static const String DELETED_TIME = 'time';

  /// Frist, nach der `cleanUp` Loeschlisteneintraege entfernt. Ein Geraet, das
  /// laenger offline war und den Eintrag noch hat, bringt ihn danach zurueck.
  static const Duration DELETED_RETENTION = Duration(days: 365);

  // Einstellungen als Register (siehe [DatabaseSettings]). Fehlt das Feld im
  // JSON, ist nichts gesetzt (null); der Wert wird dann nicht geschrieben.
  static const String SETTINGS = 'settings';

  List<VersionedEntry> _entries = List.empty(growable: true);
  final Map<dynamic, DateTime> _deleted = {};
  DatabaseSettings? _settings;

  UltracipherDatabase.fromJson(Map<String, dynamic> data) {
    // Ein altes `deleted_time` (Tombstone-Format) wird ignoriert: alte
    // Datenbanken werden nicht geladen, Altdaten kommen per CSV-Import.
    _entries = (data[ENTRIES] as List<dynamic>)
        .map((v) => VersionedEntry.fromJson(v))
        .toList(growable: true);
    var del = data[DELETED];
    if (del == null) {
      // Alte Dateien kennen die Liste nicht.
    } else if (del is List) {
      for (var item in del) {
        if (item is! Map) {
          throw FormatException(
              '$DELETED item has unexpected type ${item.runtimeType}, expected Map');
        }
        var time = item[DELETED_TIME];
        if (time is! String) {
          throw FormatException(
              '$DELETED $DELETED_TIME has unexpected type ${time.runtimeType}, expected String');
        }
        var parsed = DateTime.tryParse(time);
        if (parsed == null) {
          throw FormatException('$DELETED $DELETED_TIME not readable: $time');
        }
        _markDeleted(item[DELETED_ID], parsed);
      }
    } else {
      throw FormatException(
          '$DELETED has unexpected type ${del.runtimeType}, expected List');
    }
    _applyDeletions();
    var settings = data[SETTINGS];
    if (settings == null) {
      // Alte Dateien kennen die Einstellungen nicht: nichts gesetzt.
    } else if (settings is Map) {
      _settings = DatabaseSettings.fromJson(Map<String, dynamic>.from(settings));
    } else {
      throw FormatException(
          '$SETTINGS has unexpected type ${settings.runtimeType}, expected Map');
    }
  }

  // Traegt [id] ein; bei vorhandenem Eintrag gilt der spaetere Zeitpunkt.
  void _markDeleted(dynamic id, DateTime time) {
    var utc = time.toUtc();
    var current = _deleted[id];
    if (current == null || utc.isAfter(current)) {
      _deleted[id] = utc;
    }
  }

  /// Mergt CSV in die Datenbank, es wird nie etwas geloescht. Gibt das Ergebnis
  /// zurueck; [CsvImportResult.count] ist die Zahl der neuen Eintraege plus
  /// der Eintraege mit neuer Version (uebersprungene Zeilen zaehlen nicht).
  ///
  /// Das Format wird einmal an der ersten Zeile erkannt (ein fuehrendes BOM
  /// faellt vorher weg):
  /// - Zelle 0 `id`: `id, create date, name, tags, body`
  /// - Zelle 0 `create date`: `create date, name, tags, body` (alt, mit Kopfzeile)
  /// - sonst genau 3 Zellen: `name, tags, body` ohne Kopfzeile (aelteste
  ///   Form, App-Versionen vor 2.0.19; Zeitpunkt = jetzt)
  /// - alles andere: FormatException. Jede Zeile muss die erkannte Breite haben.
  ///
  /// Regeln je Zeile (ids als `id.toString()` verglichen):
  /// - bekannte id, Inhalt (name/tags/body) weicht von der neuesten Version
  ///   ab: neue Version mit Zeit jetzt (UTC), das CSV-Datum zaehlt nicht;
  ///   gleicher Inhalt: nichts.
  /// - unbekannte id: neuer Eintrag mit dieser id und dem CSV-Datum; steht die
  ///   id in der Loeschliste, gilt Zeit jetzt (sonst verwirft [merge] ihn gleich).
  /// - leere id oder Format ohne id: uebersprungen, wenn der Inhalt genau der
  ///   neuesten Version eines vorhandenen Eintrags gleicht (ein zweiter
  ///   Import derselben Datei erzeugt keine Duplikate), sonst neuer Eintrag
  ///   mit frischer id. Verglichen wird nur mit dem Stand vor dem Import.
  /// - Zeilen ohne Inhalt (name, tags, body leer) legen nie einen Eintrag an
  ///   und zaehlen nicht.
  /// - Eine unbekannte id, die eine kanonische Ganzzahl ist, wird als int
  ///   angelegt (siehe [_typedId]).
  /// - dieselbe nicht leere id zweimal in einer Datei: FormatException.
  ///
  /// Alles wird zuerst geprueft und geplant; erst danach wird geschrieben.
  /// Bei einem Fehler bleibt die Datenbank unveraendert. Die Fehlermeldungen
  /// nennen nie den Inhalt einer Zelle (Klartext), nur Satznummern (N-ter CSV-Satz, die Kopfzeile zaehlt mit).
  CsvImportResult importFromCsv(
    String csv, {
    String fieldDelimiter = ',',
    String textDelimiter = '"',
  }) {
    if (csv.startsWith('\uFEFF')) {
      csv = csv.substring(1);
    }
    var rows = Csv(
            fieldDelimiter: fieldDelimiter,
            quoteCharacter: textDelimiter,
            autoDetect: false)
        .decode(csv);
    var added = <VersionedEntry>[];
    var changed = <MapEntry<VersionedEntry, Entry>>[];
    if (rows.isEmpty) {
      return CsvImportResult._(this, added, changed);
    }

    // Format aus der ersten Zeile.
    var firstCell = rows[0][0].toString().trim().toLowerCase();
    List<String>? header;
    if (firstCell == CSV_HEADER[0]) {
      header = CSV_HEADER;
    } else if (firstCell == CSV_HEADER_WITHOUT_ID[0]) {
      header = CSV_HEADER_WITHOUT_ID;
    }
    int width;
    int start;
    if (header != null) {
      width = header.length;
      start = 1;
      var firstRow = rows[0];
      if (firstRow.length != width ||
          !IterableEquality<String>().equals(
              firstRow.map((c) => c.toString().trim().toLowerCase()), header)) {
        throw FormatException('CSV record 1: header not recognised');
      }
    } else if (rows[0].length == 3) {
      width = 3;
      start = 0;
    } else {
      throw FormatException(
          'CSV record 1: format not recognised (${rows[0].length} columns, no header)');
    }
    var hasId = width == CSV_HEADER.length;
    var hasDate = width >= CSV_HEADER_WITHOUT_ID.length;

    // Stand vor dem Import (nur lesen).
    var byId = <String, VersionedEntry>{};
    for (var e in _entries) {
      byId.putIfAbsent(e.id.toString(), () => e);
    }
    var deletedAt = <String, DateTime>{};
    _deleted.forEach((id, time) {
      var key = id.toString();
      var current = deletedAt[key];
      if (current == null || time.isAfter(current)) deletedAt[key] = time;
    });
    var existingContent = <String>{};
    for (var e in _entries) {
      var latest = e.latestEntry;
      if (latest != null) existingContent.add(latest._textKey);
    }

    var now = DateTime.now().toUtc();
    var nowString = now.toIso8601String();
    var seenIds = <String>{};

    // Schritt 1: Pruefen und planen, die Datenbank bleibt unberuehrt.
    for (var i = start; i < rows.length; i++) {
      var row = rows[i];
      var lineNo = i + 1;
      if (row.length != width) {
        throw FormatException(
            'CSV record $lineNo: ${row.length} columns instead of $width');
      }
      var id = hasId ? row[0].toString() : '';
      String? csvTime;
      if (hasDate) {
        var dateCell = row[width - 4].toString().trim();
        if (dateCell.isNotEmpty) {
          if (DateTime.tryParse(dateCell) == null) {
            throw FormatException('CSV record $lineNo: date not readable');
          }
          csvTime = dateCell;
        }
      }
      Entry version(String time) => Entry(
          label: row[width - 3].toString(),
          tags: row[width - 2].toString(),
          content: row[width - 1].toString(),
          createTime: time);

      if (id.isEmpty) {
        var entry = version(csvTime ?? nowString);
        // Leere Zeilen legen nichts an: ein Eintrag ohne Inhalt wird von
        // cleanUp mit der Loeschzeit jetzt geloescht und das Merge entfernte
        // dann auch die Historie des Eintrags auf der Gegenseite.
        if (entry.isEmpty) continue;
        if (existingContent.contains(entry._textKey)) continue;
        added.add(VersionedEntry(_newID())..addNewVersion(entry));
        continue;
      }
      if (!seenIds.add(id)) {
        throw FormatException('CSV record $lineNo: duplicate id');
      }
      var existing = byId[id];
      if (existing != null) {
        var latest = existing.latestEntry;
        var entry = version(_laterThan(now, latest?.createDateTime));
        if (latest != null && latest._textKey == entry._textKey) continue;
        changed.add(MapEntry(existing, entry));
      } else {
        var time = deletedAt[id];
        var entry =
            version(time == null ? csvTime ?? nowString : _laterThan(now, time));
        if (entry.isEmpty) continue; // siehe oben
        added.add(VersionedEntry(_typedId(id))..addNewVersion(entry));
      }
    }

    // Schritt 2: Erst jetzt in die Datenbank schreiben.
    for (var e in added) {
      _addEntry(e);
    }
    for (var c in changed) {
      c.key.addNewVersion(c.value);
    }
    return CsvImportResult._(this, added, changed);
  }

  // Alte Datenbanken haben teils int-ids; `merge` vergleicht ids mit ==, ein
  // String "5" neben einem int 5 gaebe zwei Eintraege. Eine kanonische
  // Ganzzahl (so wie toString sie schreibt) wird deshalb wieder int; der
  // Export schreibt dieselbe Zeichenfolge, der Roundtrip bleibt gleich.
  static dynamic _typedId(String id) {
    var n = int.tryParse(id);
    return n != null && n.toString() == id ? n : id;
  }

  // [now] als Zeitstempel, aber nie nicht nach [other] (Uhrabweichung): sonst
  // wuerde die neue Version nicht die neueste bzw. von der Loeschung verworfen.
  static String _laterThan(DateTime now, DateTime? other) {
    if (other == null || now.isAfter(other)) return now.toIso8601String();
    return other.toUtc().add(Duration(milliseconds: 1)).toIso8601String();
  }

  UltracipherDatabase();

  Map<String, dynamic> toJson() {
    var map = <String, dynamic>{};
    map[ENTRIES] = _entries.map((e) => e.toJson()).toList();
    var ids = _deleted.keys.toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));
    map[DELETED] = [
      for (var id in ids)
        {DELETED_ID: id, DELETED_TIME: _deleted[id]!.toIso8601String()}
    ];
    var settings = _settings;
    if (settings != null) {
      map[SETTINGS] = settings.toJson();
    }
    return map;
  }

  /// CSV mit den Spalten [CSV_HEADER], eine Zeile je Eintrag (neueste Version).
  /// In Einfuegereihenfolge, nicht nach getEntries: dessen Sortierung ist nicht
  /// stabil, ein zweiter Export derselben Daten waere sonst anders geordnet.
  /// Die Einstellungen stehen nie im CSV.
  String toCSV({String fieldDelimiter = ',', String textDelimiter = '"'}) {
    var values = <List<dynamic>>[CSV_HEADER];
    for (var entry in _entries) {
      var le = entry.latestEntry;
      if (le == null) {
        continue;
      }
      values.add(
          [entry.id.toString(), le.createTime, le.label, le.tags, le.content]);
    }
    return Csv(fieldDelimiter: fieldDelimiter, quoteCharacter: textDelimiter)
        .encode(values);
  }

  String _newID() => Uuid().v4();

  // List<dynamic?> get _entries => _map[ENTRIES];

  /// Spaetester Zeitpunkt aus den neuesten Versionen aller Eintraege und der
  /// Loeschliste.
  DateTime get lastChangedTime {
    var time = DateTime(1);
    for (var en in _entries) {
      var t = en.latestChangeTime;
      if (t != null && t.isAfter(time)) {
        time = t;
      }
    }
    for (var t in _deleted.values) {
      if (t.isAfter(time)) {
        time = t;
      }
    }
    return time;
  }

  /// Kopie der Loeschliste (id -> Zeitpunkt der Loeschung, UTC).
  Map<dynamic, DateTime> get deletions => Map.of(_deleted);

  /// Ersetzt die Loeschliste durch eine Kopie von [deletions] (Rollback).
  void restoreDeletions(Map<dynamic, DateTime> deletions) {
    _deleted.clear();
    deletions.forEach(_markDeleted);
  }

  /// Die Einstellungen der Datenbank oder null, wenn nie etwas gesetzt wurde.
  /// Der Wert ist unveraenderlich. Die Einstellungen stehen nie im CSV-Export.
  DatabaseSettings? get settings => _settings;

  /// Setzt die Einstellungen neu. [github] null heisst ausdruecklich "GitHub
  /// entfernt" und gewinnt mit seinem Zeitstempel gegen aeltere Werte. [time]
  /// ist der Aenderungszeitpunkt (Standard: jetzt); er entscheidet beim
  /// [merge], welcher Wert gilt.
  void setSettings({GithubSettings? github, DateTime? time}) {
    _settings = DatabaseSettings(time: time ?? DateTime.now(), github: github);
  }

  VersionedEntry? getEntryWhitId(dynamic id) {
    return _entries.firstWhereOrNull((e) => e.id == id);
  }

  List<VersionedEntry> get allEntries => List.from(_entries);

  List<VersionedEntry> getEntries({String? searchTerm}) {
    searchTerm ??= '';
    var terms = searchTerm
        .trim()
        .split(" ")
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    var resultList = <List<dynamic>>[];
    for (var versionedEntry in allEntries) {
      var score = 0;
      var latestEntry = versionedEntry.latestEntry;
      if (latestEntry == null) {
        continue;
      }
      score += latestEntry.match(terms);
      if (score > 0) {
        resultList.add([score, versionedEntry]);
      }
    }
    //Nach score absteigend sortieren
    resultList.sort((a, b) => (b[0] as int).compareTo(a[0] as int));
    return resultList.map((l) => l[1] as VersionedEntry).toList(growable: true);
  }

  /// Fuegt [entry] ein (Standard: neuer Eintrag mit frischer id). Steht die id
  /// in der Loeschliste und hat der Eintrag schon Versionen, werden die
  /// Versionen bis zum Loeschzeitpunkt verworfen; bleibt keine uebrig, wird er
  /// nicht eingefuegt (siehe [merge]).
  VersionedEntry addEntry({VersionedEntry? entry}) {
    entry ??= VersionedEntry(_newID());
    var deletedAt = _deleted[entry.id];
    if (deletedAt != null && entry.versions.isNotEmpty) {
      entry._dropVersionsUpTo(deletedAt);
      if (entry.versions.isEmpty) {
        return entry;
      }
    }
    _addEntry(entry);
    return entry;
  }

  void _addEntry(VersionedEntry entry) {
    _entries.add(entry);
  }

  /// Haengt [version] an den Eintrag mit der id von [entry] (bei null: an
  /// einen neuen Eintrag) und gibt den Eintrag zurueck, an dem sie jetzt
  /// haengt.
  ///
  /// [entry] kann seit dem Oeffnen aus der Datenbank verschwunden sein (ein
  /// Sync hat eine Loeschung gemergt; dabei wird das Objekt entfernt). Dann
  /// gilt die Bearbeitung als die neuere Aktion: der Eintrag kommt wieder
  /// hinein, seine durch die Loeschung gedeckten alten Versionen entfallen,
  /// die neue Version (Zeit jetzt) bleibt. Sonst haengte die Version an einem
  /// losgeloesten Objekt und ginge still verloren.
  VersionedEntry addVersion(VersionedEntry? entry, Entry version) {
    VersionedEntry target;
    if (entry == null) {
      target = addEntry();
    } else {
      var current = getEntryWhitId(entry.id);
      if (current == null) {
        addEntry(entry: entry); // wendet die Loeschliste an
        if (getEntryWhitId(entry.id) == null) {
          // Alle alten Versionen waren durch die Loeschung gedeckt.
          _addEntry(entry);
        }
        current = entry;
      }
      target = current;
    }
    target.addNewVersion(version);
    return target;
  }

  /// Nimmt [version] (genau dieses Objekt) von [entry] zurueck, falls sie noch
  /// da ist, und entfernt den Eintrag, wenn er danach keine Version mehr hat.
  /// Gegenstueck zu [addVersion] fuer das Zurueckrollen einer Bearbeitung.
  void removeVersion(VersionedEntry entry, Entry version) {
    var current = getEntryWhitId(entry.id) ?? entry;
    current._removeVersion(version);
    if (current.versions.isEmpty) {
      removeEntry(current);
    }
  }

  void removeEntry(VersionedEntry entry) {
    _entries.remove(entry);
  }

  /// Loescht [entry]: Der Eintrag samt allen Versionen verschwindet aus der
  /// Datenbank, seine id steht mit [deletedAt] (Standard: jetzt) in der
  /// Loeschliste, damit `merge` ihn von der Gegenseite nicht zurueckholt.
  void deleteEntry(VersionedEntry entry, {DateTime? deletedAt}) {
    removeEntry(entry);
    _markDeleted(entry.id, deletedAt ?? DateTime.now());
  }

  /*
  * Loescht alle leeren Eintraege (ueber [deleteEntry], die id kommt also mit
  * der aktuellen Zeit in die Loeschliste) und entfernt Loeschlisteneintraege,
  * die aelter als [deleteOlderThat] sind.
  */
  void cleanUp({Duration deleteOlderThat = DELETED_RETENTION}) {
    var now = DateTime.now();
    for (var entry in allEntries) {
      if (entry.isEmpty) {
        deleteEntry(entry, deletedAt: now);
      }
    }
    var threshold = now.subtract(deleteOlderThat);
    _deleted.removeWhere((_, time) => time.isBefore(threshold));
  }

  /// Vereinigt [other] in diese Datenbank ([other] bleibt unveraendert, es
  /// werden keine Objekte geteilt). Kommutativ, assoziativ und idempotent (als
  /// Menge; nur die Kopfversion bei exakt gleicher Zeit haengt von der Seite
  /// ab). Ausgenommen ist das Entfernen alter Loeschlisteneintraege in
  /// [cleanUp]:
  /// 1. Loeschliste = Vereinigung, je id gilt der spaetere Zeitpunkt.
  /// 2. Eintraege = Vereinigung ueber die id, Versionen werden vereinigt.
  /// 3. Je id der Loeschliste werden alle Versionen mit Zeit <= Loeschzeitpunkt
  ///    verworfen (gleich alt = verworfen). Bleibt keine uebrig, ist der
  ///    Eintrag weg, sonst lebt er mit den neueren Versionen. Die id bleibt
  ///    immer in der Liste.
  /// 4. Einstellungen = Register, der spaetere Zeitstempel gewinnt; bei
  ///    gleicher Zeit der lexikografisch groessere kanonische JSON-String
  ///    (siehe [DatabaseSettings.compareTo]). Eine Kopie, kein geteiltes Objekt.
  void merge(UltracipherDatabase other) {
    // Zuerst Schnappschuesse, damit a.merge(a) nichts waehrend des Laufs sieht.
    var otherEntries = other.allEntries;
    var otherDeleted = Map<dynamic, DateTime>.of(other._deleted);
    var otherSettings = other._settings;

    otherDeleted.forEach(_markDeleted);

    for (var otherEntry in otherEntries) {
      var localEntry = getEntryWhitId(otherEntry.id);
      if (localEntry == null) {
        _addEntry(VersionedEntry.fromJson(otherEntry.toJson()));
      } else {
        localEntry.merge(otherEntry);
      }
    }

    _applyDeletions();

    if (otherSettings != null) {
      var mine = _settings;
      if (mine == null || otherSettings.compareTo(mine) > 0) {
        _settings = DatabaseSettings.fromJson(otherSettings.toJson());
      }
    }
  }

  // Regel 3 von [merge] fuer alle Eintraege.
  void _applyDeletions() {
    for (var id in _deleted.keys.toList()) {
      var entry = getEntryWhitId(id);
      if (entry == null) {
        continue;
      }
      entry._dropVersionsUpTo(_deleted[id]!);
      if (entry.versions.isEmpty) {
        removeEntry(entry);
      }
    }
  }

  /// Gleicher Inhalt: gleiche Menge von Eintrags-ids, gleiche Loeschliste (id
  /// und Zeitpunkt), gleiche Einstellungen (Zeitpunkt und Wert) und je Eintrag
  /// gleiche Menge von Versionen (createTime, label, tags, content). Die
  /// Reihenfolge ist egal.
  bool hasSameContentAs(UltracipherDatabase other) {
    if (_entries.length != other._entries.length ||
        _deleted.length != other._deleted.length) {
      return false;
    }
    if (_settings != other._settings) {
      return false;
    }
    for (var id in _deleted.keys) {
      var t = other._deleted[id];
      if (t == null || !t.isAtSameMomentAs(_deleted[id]!)) {
        return false;
      }
    }
    for (var entry in _entries) {
      var o = other.getEntryWhitId(entry.id);
      if (o == null || !entry._hasSameVersionsAs(o)) {
        return false;
      }
    }
    return true;
  }
}

// Object.hash gibt es erst ab SDK 2.14, die Untergrenze des Projekts ist 2.12.
int _combineHashes(List<Object?> parts) {
  var hash = 17;
  for (var part in parts) {
    hash = (hash * 31 + part.hashCode) & 0x1fffffff;
  }
  return hash;
}

/// GitHub-Zugang als backend-neutraler Wert im Modell (kein Import aus
/// `backend/`). Core baut daraus das `GithubBackend`.
///
/// Unveraenderlich. [toString] enthaelt das Token nie.
class GithubSettings {
  static const String TOKEN = 'token';
  static const String OWNER = 'owner';
  static const String REPO = 'repo';
  static const String BRANCH = 'branch';

  final String token;
  final String owner;
  final String repo;
  final String branch;

  const GithubSettings({
    required this.token,
    required this.owner,
    required this.repo,
    required this.branch,
  });

  /// Alle vier Felder muessen Strings sein. Die Fehlermeldungen nennen nur
  /// Feldnamen und Typen, nie einen Wert (das Token darf nirgends landen).
  factory GithubSettings.fromJson(Map<String, dynamic> data) {
    String field(String name) {
      var value = data[name];
      if (value is! String) {
        throw FormatException(
            'github $name has unexpected type ${value.runtimeType}, expected String');
      }
      return value;
    }

    return GithubSettings(
        token: field(TOKEN),
        owner: field(OWNER),
        repo: field(REPO),
        branch: field(BRANCH));
  }

  // Feste Schluesselreihenfolge: [DatabaseSettings] nutzt die JSON-Zeichenkette
  // als kanonische Form fuer den Tie-Break.
  Map<String, dynamic> toJson() =>
      {TOKEN: token, OWNER: owner, REPO: repo, BRANCH: branch};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GithubSettings &&
          token == other.token &&
          owner == other.owner &&
          repo == other.repo &&
          branch == other.branch;

  @override
  int get hashCode => _combineHashes([token, owner, repo, branch]);

  // Ohne Token: ein zufaellig in einen Log geratenes toString darf nichts
  // preisgeben.
  @override
  String toString() =>
      'GithubSettings(owner: $owner, repo: $repo, branch: $branch)';
}

/// Einstellungen einer Datenbank als Last-Writer-Wins-Register.
///
/// [time] ist der Aenderungszeitpunkt (UTC). [github] null ist ein ausdruecklicher
/// Wert ("GitHub entfernt") und gewinnt mit neuerer [time] gegen aeltere Werte.
/// Ein fehlendes Register (`UltracipherDatabase.settings == null`) heisst
/// dagegen "nie etwas gesetzt" und verliert gegen jeden Wert.
class DatabaseSettings implements Comparable<DatabaseSettings> {
  static const String TIME = 'time';
  static const String GITHUB = 'github';

  final DateTime time;
  final GithubSettings? github;

  DatabaseSettings({required DateTime time, this.github}) : time = time.toUtc();

  factory DatabaseSettings.fromJson(Map<String, dynamic> data) {
    var time = data[TIME];
    if (time is! String) {
      throw FormatException(
          'settings $TIME has unexpected type ${time.runtimeType}, expected String');
    }
    var parsed = DateTime.tryParse(time);
    if (parsed == null) {
      throw FormatException('settings $TIME not readable: $time');
    }
    // `github: null` ist ein Wert, ein fehlender Schluessel nicht.
    if (!data.containsKey(GITHUB)) {
      throw FormatException('settings $GITHUB missing');
    }
    var github = data[GITHUB];
    if (github == null) {
      return DatabaseSettings(time: parsed);
    }
    if (github is! Map) {
      throw FormatException(
          'settings $GITHUB has unexpected type ${github.runtimeType}, expected Map');
    }
    return DatabaseSettings(
        time: parsed,
        github: GithubSettings.fromJson(Map<String, dynamic>.from(github)));
  }

  Map<String, dynamic> toJson() => {
        TIME: time.toIso8601String(),
        GITHUB: github?.toJson(),
      };

  // Kanonische Form des Werts fuer den Tie-Break bei gleicher Zeit.
  String get _canonicalValue => jsonEncode(github?.toJson());

  /// Gesamtordnung: erst nach [time] (als Zeitpunkt), bei gleicher Zeit nach
  /// dem kanonischen JSON-String des Werts. Das Maximum darunter ist
  /// kommutativ, assoziativ und idempotent.
  @override
  int compareTo(DatabaseSettings other) {
    var byTime = time.compareTo(other.time);
    if (byTime != 0) return byTime;
    return _canonicalValue.compareTo(other._canonicalValue);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DatabaseSettings &&
          time.isAtSameMomentAs(other.time) &&
          github == other.github;

  @override
  int get hashCode => _combineHashes([time.microsecondsSinceEpoch, github]);

  @override
  String toString() => 'DatabaseSettings(time: ${time.toIso8601String()}, '
      'github: ${github ?? 'none'})';
}

/// Ergebnis von [UltracipherDatabase.importFromCsv].
class CsvImportResult {
  CsvImportResult._(this._db, this.added, this._changed);

  final UltracipherDatabase _db;

  /// Die neu angelegten Eintraege.
  final List<VersionedEntry> added;
  final List<MapEntry<VersionedEntry, Entry>> _changed;

  /// Neue Eintraege plus Eintraege mit neuer Version.
  int get count => added.length + _changed.length;

  /// Nimmt den Import zurueck (genau das, was er angelegt hat). Fuer den Fall,
  /// dass das anschliessende Speichern scheitert; der Import loescht nichts,
  /// also gibt es auch nichts wiederherzustellen.
  void undo() {
    for (var e in added) {
      _db.removeEntry(e);
    }
    for (var c in _changed) {
      _db.removeVersion(c.key, c.value);
    }
  }
}

class VersionedEntry {
  static const String VERSIONS = 'versions';
  static const String ID = 'id';

  dynamic id;
  List<Entry> _versions = List.empty(growable: true);

  VersionedEntry.fromJson(Map<String, dynamic> data) {
    id = data[ID];
    var e = data[VERSIONS];
    if (e == null) {
      // Legacy/absent versions list: tolerate as an entry with no versions yet.
      _versions = List.empty(growable: true);
    } else if (e is List) {
      _versions = e.map((d) => Entry.fromJson(d)).toList(growable: true);
    } else {
      throw FormatException(
          '$VERSIONS has unexpected type ${e.runtimeType}, expected List');
    }
  }

  VersionedEntry(this.id) {
    _versions = List.empty(growable: true);
  }

  Map<String, dynamic> toJson() {
    var ret = <String, dynamic>{};
    ret[ID] = id;
    ret[VERSIONS] = _versions.map((v) => v.toJson()).toList();

    return ret;
  }

  List<Entry> get versions {
    return UnmodifiableListView( _versions);
  }

  void addNewVersion(Entry entry) {
    _versions.insert(0, entry);
    _sortVersions();
  }

  // Verwirft alle Versionen mit Zeit <= [time] (gleich alt = verworfen).
  void _dropVersionsUpTo(DateTime time) {
    _versions.removeWhere((v) => !v.createDateTime.isAfter(time));
  }

  void _removeVersion(Entry version) {
    _versions.removeWhere((v) => identical(v, version));
  }

  // Absteigend nach Zeit. mergeSort ist stabil: bei gleicher Zeit bleibt die
  // Reihenfolge erhalten (siehe merge).
  void _sortVersions() {
    mergeSort(_versions,
        compare: (Entry a, Entry b) =>
            b.createDateTime.compareTo(a.createDateTime));
  }

  Entry? get latestEntry => _versions.firstOrNull;

  /// Zeit der juengsten Version (Maximum ueber alle Versionen, unabhaengig von
  /// der Reihenfolge der Liste).
  DateTime? get latestChangeTime {
    DateTime? latest;
    for (var v in _versions) {
      var t = v.createDateTime;
      if (latest == null || t.isAfter(latest)) latest = t;
    }
    return latest;
  }

  bool get isEmpty =>
      _versions.isEmpty || !_versions.any((element) => !element.isEmpty);

  @override
  String toString() {
    return 'VersionedEntry{latestEntry: $latestEntry';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VersionedEntry &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  /// Vereinigt die Versionen von [other] in diese. Dedupe ueber (createTime,
  /// label, tags, content): gleiche Zeit mit verschiedenem Inhalt bleibt als
  /// zwei Versionen erhalten, die eigene steht bei gleicher Zeit vorn. Die
  /// Versionen von [other] werden kopiert, nicht geteilt.
  void merge(VersionedEntry other) {
    var otherVersions = List<Entry>.of(other._versions);
    var keys = <String>{};
    var result = <Entry>[];
    for (var e in _versions) {
      if (keys.add(e._contentKey)) result.add(e);
    }
    for (var e in otherVersions) {
      if (keys.add(e._contentKey)) result.add(Entry.fromJson(e.toJson()));
    }
    _versions = result;
    _sortVersions();
  }

  bool _hasSameVersionsAs(VersionedEntry other) {
    var mine = _versions.map((e) => e._contentKey).toSet();
    var theirs = other._versions.map((e) => e._contentKey).toSet();
    return mine.length == theirs.length && mine.containsAll(theirs);
  }
}

class Entry {
  static const String LABEL = 'label';
  static const String TAGS = 'tags';
  static const String CREATE_TIME = 'time';
  static const String CONTENT = 'content';

  late ObfuscatedString _label;
  late ObfuscatedString _tags;
  late ObfuscatedString _content;
  late String _createTime;

  String get createTime => _createTime;

  set createTime(String val) {
    _parsedTime = DateTime.tryParse(val);
    _createTime = val;
  }

  DateTime? _parsedTime;

  DateTime get createDateTime {
    _parsedTime ??= DateTime.parse(createTime);
    return _parsedTime!;
  }

  Entry(
      {String? label = '',
      String? tags = '',
      String? content = '',
      String? createTime}) {
    // Neue Zeitstempel immer in UTC (Suffix Z), damit Geraete in verschiedenen
    // Zeitzonen dieselbe Reihenfolge sehen. Vergleiche laufen nach Zeitpunkt.
    _createTime = createTime ?? DateTime.now().toUtc().toIso8601String();
    _label = ObfuscatedString(label ?? "");
    _tags = ObfuscatedString(tags ?? "");
    _content = ObfuscatedString(content ?? "");
  }

  Entry.fromJson(Map<String, dynamic> map)
      : this(label: map[LABEL], tags: map[TAGS], content: map[CONTENT], createTime: map[CREATE_TIME]);

  Map<String, dynamic> toJson() {
    var ret = <String, dynamic>{};
    ret[LABEL] = label;
    ret[TAGS] = tags;
    ret[CREATE_TIME] = createTime;
    ret[CONTENT] = content;
    return ret;
  }

  @override
  String toString() {
    return 'Entry{label: $label, tags: $tags, parsedTime: $_parsedTime}';
  }

  String get label => _label.plainValue;

  set label(String val) => _label = ObfuscatedString(val);

  String get tags => _tags.plainValue;

  set tags(String val) => _tags = ObfuscatedString(val);

  String get content => _content.plainValue;

  set content(String val) => _content = ObfuscatedString(val);

  bool get isEmpty => _content.isEmpty && _tags.isEmpty && _label.isEmpty;

  // Nur der Text (ohne Zeit): gleicher Inhalt beim CSV-Import.
  String get _textKey => jsonEncode([label, tags, content]);

  // Schluessel zum Vergleichen/Deduplizieren von Versionen.
  String get _contentKey => jsonEncode([createTime, label, tags, content]);

  int match(List<String> terms){
    if(terms.isEmpty) {
      return 1;
    }
    int counter = 0;
    for(var str in terms){
      counter += _label.containsIgnoreCase(str) ? 1 : 0;
      counter += _tags.containsIgnoreCase(str) ? 1 : 0;
      counter += _content.containsIgnoreCase(str) ? 1 : 0;
    }
    return counter;
  }
}

class ObfuscatedString {
  late Uint32List _encryptedValue;
  late Uint32List _key;

  ObfuscatedString(String str) {
    var src = str.trim().codeUnits;
    _encryptedValue = Uint32List(src.length);
    if(_encryptedValue.isEmpty) return;
    _key = Uint32List(src.length);
      for (int i = 0; i < _key.length; i++) {
        _key[i] = Random().nextInt(0xffffff);
      }

    for (int i = 0; i < _encryptedValue.length; i++) {
      int k = _key[i];
      _encryptedValue[i] = src[i] ^ k;
    }
  }

  bool contains(String str){
    List<int> codeUnits = _decrypt();
    List<int> pattern = str.codeUnits;
    var ret = codeUnits.indexOfSubList(pattern) >=0 ;
    _fillWithGarbage(codeUnits);
    return ret;
  }
  /// Suche ohne Beachtung der Groß-/Kleinschreibung. Gefaltet wird pro
  /// Zeichen (nicht über einen String des Klartexts), damit der Klartext
  /// nicht als String im Speicher landet.
  bool containsIgnoreCase(String str){
    List<int> codeUnits = _decrypt();
    for (var i = 0; i < codeUnits.length; i++) {
      codeUnits[i] = _foldCase(codeUnits[i]);
    }
    List<int> pattern = str.codeUnits.map(_foldCase).toList(growable: false);
    var ret = codeUnits.indexOfSubList(pattern) >= 0;
    _fillWithGarbage(codeUnits);
    return ret;
  }

  // Nur 1:1-Abbildungen übernehmen, damit die Länge gleich bleibt.
  static int _foldCase(int unit) {
    var lower = String.fromCharCode(unit).toLowerCase().codeUnits;
    return lower.length == 1 ? lower[0] : unit;
  }

  bool get isEmpty => _encryptedValue.isEmpty;

  String get plainValue {
    List<int> codeUnits = _decrypt();
    var ret = String.fromCharCodes(codeUnits);
    _fillWithGarbage(codeUnits);
    return ret;
  }

  void _fillWithGarbage(List<int> codeUnits) {
    for(int i = 0; i < codeUnits.length; i++){
      codeUnits[i] = Random().nextInt(0x1A) + 0x60;
    }
  }

  List<int> _decrypt() {

    List<int> codeUnits = List.generate(
        _encryptedValue.length, (i) => _key[i] ^ _encryptedValue[i]);
    return codeUnits;
  }
}
