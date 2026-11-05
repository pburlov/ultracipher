import 'package:flutter/foundation.dart';

/// Ein Eintrag des Sync-Logs: eine GitHub-Anfrage samt Antwort oder ein
/// Wechsel des Sync-Status. Nur Diagnosefelder, nie Token, Header
/// `Authorization`, URLs, Datenbankinhalt oder der volle Datenbankname.
class SyncLogEntry {
  final DateTime time;

  /// z. B. `read file`, `read blob`, `put`, `delete`, `resolve owner`,
  /// `status`.
  final String operation;
  final String? method;

  /// Kategorie des Endpunkts (`contents`, `git/blobs`, `user`), nie die URL.
  final String? endpoint;
  final int? status;

  /// `ok` oder die Fehlerart (authRequired, rateLimit, remoteMissing,
  /// conflict, network, timeout, parseError, httpError, notFound); bei
  /// Statuswechseln der neue Zustand.
  final String result;

  /// `message` und `documentation_url` aus dem GitHub-Fehler-JSON (gekürzt).
  final String? message;
  final String? documentationUrl;
  final String? owner;
  final String? repo;
  final String? branch;

  /// Nur der maskierte Pfad (`abcdef...<.txt`).
  final String? path;

  /// Nur eine feste Auswahl harmloser Antwort-Header.
  final Map<String, String> headers;

  /// Freitext, bei Statuswechseln `alt -> neu: Fehlertext`.
  final String? detail;

  const SyncLogEntry({
    required this.time,
    required this.operation,
    required this.result,
    this.method,
    this.endpoint,
    this.status,
    this.message,
    this.documentationUrl,
    this.owner,
    this.repo,
    this.branch,
    this.path,
    this.headers = const {},
    this.detail,
  });

  /// Ein Eintrag als Text (mehrere Zeilen), derselbe Text in der Anzeige und
  /// in "Copy".
  String toText() {
    var head = StringBuffer(time.toUtc().toIso8601String())
      ..write('  ')
      ..write(operation);
    if (method != null) head.write('  $method');
    if (endpoint != null) head.write(' $endpoint');
    if (status != null) head.write('  $status');
    head.write('  $result');
    var buf = StringBuffer(head);
    var target = [
      if (owner != null) 'owner=$owner',
      if (repo != null) 'repo=$repo',
      if (branch != null) 'branch=$branch',
      if (path != null) 'path=$path',
    ];
    if (target.isNotEmpty) buf.write('\n  ${target.join(' ')}');
    if (message != null) buf.write('\n  message: $message');
    if (documentationUrl != null) {
      buf.write('\n  documentation_url: $documentationUrl');
    }
    if (headers.isNotEmpty) {
      buf.write('\n  headers: '
          '${headers.entries.map((e) => '${e.key}=${e.value}').join('; ')}');
    }
    if (detail != null) buf.write('\n  $detail');
    return buf.toString();
  }
}

/// Sync-Log: Ringpuffer der letzten [capacity] Einträge, nur im Speicher
/// (nicht persistent, nie in der Konsole). Dient der Fehlersuche bei einem
/// Sync, der nur "404" meldet.
///
/// HARTE REGEL: nie Token, Authorization-Header, Query-Strings, Datenbank-
/// inhalt (Klartext, Ciphertext, base64) oder den ungekürzten Datenbanknamen
/// hineinschreiben. Das Log selbst wirft nie: jeder Aufruf fängt alle
/// Fehler, damit die Diagnose den Sync nicht stören kann.
class SyncLog extends ChangeNotifier {
  static const int defaultCapacity = 200;

  /// Obergrenze für Texte aus der Antwort (message, documentation_url).
  static const int maxTextLength = 300;

  final int capacity;

  /// Testnaht: die Uhr.
  @visibleForTesting
  DateTime Function() now;

  final List<SyncLogEntry> _entries = [];

  int _epoch = 0;

  /// Steigt bei jedem [clear] (Sitzungswechsel). Eine Anfrage merkt sich die
  /// Epoche beim Start; ihr Eintrag mit einer alten Epoche wird verworfen,
  /// damit ein Spätschreiber der alten Sitzung das neue Log nicht füllt.
  int get epoch => _epoch;

  SyncLog({this.capacity = defaultCapacity, DateTime Function()? now})
      : now = now ?? (() => DateTime.now());

  /// Neueste zuerst.
  List<SyncLogEntry> get entries => List.unmodifiable(_entries.reversed);

  int get length => _entries.length;

  /// Kürzt [text] hart auf [max] Zeichen und macht eine Zeile daraus
  /// (Zeilenumbrüche aus einer Antwort dürfen das Format nicht aufbrechen).
  static String clip(String text, [int max = maxTextLength]) {
    var oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= max ? oneLine : oneLine.substring(0, max);
  }

  /// Trägt einen Eintrag mit der Zeit der Uhr ein; beim Überlauf fällt der
  /// älteste heraus.
  void record({
    required String operation,
    required String result,
    String? method,
    String? endpoint,
    int? status,
    String? message,
    String? documentationUrl,
    String? owner,
    String? repo,
    String? branch,
    String? path,
    Map<String, String> headers = const {},
    String? detail,
    int? epoch,
  }) {
    try {
      if (epoch != null && epoch != _epoch) return;
      String? c(String? s) => s == null ? null : clip(s);
      _entries.add(SyncLogEntry(
        time: now(),
        operation: operation,
        result: clip(result),
        method: method,
        endpoint: endpoint,
        status: status,
        message: c(message),
        documentationUrl: c(documentationUrl),
        owner: c(owner),
        repo: c(repo),
        branch: c(branch),
        path: c(path),
        headers: {for (var e in headers.entries) e.key: clip(e.value, 100)},
        detail: c(detail),
      ));
      while (_entries.length > capacity) {
        _entries.removeAt(0);
      }
      notifyListeners();
    } catch (_) {
      // Die Diagnose darf nie einen Fehler auslösen.
    }
  }

  void clear() {
    try {
      _epoch++;
      _entries.clear();
      notifyListeners();
    } catch (_) {
      // s. o.
    }
  }

  /// Das ganze Log als ein Text, neueste zuerst (Anzeige und "Copy").
  String toText() {
    try {
      return entries.map((e) => e.toText()).join('\n');
    } catch (_) {
      return '';
    }
  }
}
