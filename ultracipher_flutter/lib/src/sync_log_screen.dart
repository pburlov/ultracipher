import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ultracipher_flutter/src/core.dart';

import 'sync_log.dart';

/// Bildschirm "Sync log": die letzten Sync-Vorgänge (GitHub-Anfragen,
/// Statuswechsel), neueste zuerst, mit "Copy" (alles als ein Text in die
/// Zwischenablage) und "Clear". Das Log liegt nur im Speicher und enthält nie
/// Token, Inhalt oder den vollen Datenbanknamen (siehe [SyncLog]). Auch ohne
/// Fehler erreichbar (GitHub-Einstellungen).
class SyncLogScreen extends StatelessWidget {
  /// Testnaht: ein anderes Log statt dem der App.
  final SyncLog? log;

  const SyncLogScreen({Key? key, this.log}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var log = this.log ?? UltracipherApp.instance.syncLog;
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) {
        var entries = log.entries;
        return Scaffold(
          appBar: AppBar(
            title: Text('Sync log'),
            actions: [
              IconButton(
                key: const Key('syncLogCopy'),
                tooltip: 'Copy',
                icon: Icon(Icons.copy),
                onPressed: () async {
                  var messenger = ScaffoldMessenger.of(context);
                  await Clipboard.setData(ClipboardData(text: log.toText()));
                  messenger
                      .showSnackBar(SnackBar(content: Text('Sync log copied')));
                },
              ),
              IconButton(
                key: const Key('syncLogClear'),
                tooltip: 'Clear',
                icon: Icon(Icons.delete_outline),
                onPressed: entries.isEmpty ? null : log.clear,
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Text(
                    'Contains account, repository and branch; check before '
                    'sharing.',
                    key: const Key('syncLogHint'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Expanded(child: _body(entries)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _body(List<SyncLogEntry> entries) {
    return entries.isEmpty
        ? Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No entries yet. The log is kept in memory '
                  'only and is gone when the app closes.'),
            ),
          )
        : ListView.separated(
            padding: EdgeInsets.all(12),
            itemCount: entries.length,
            separatorBuilder: (_, __) => Divider(),
            itemBuilder: (context, i) => SelectableText(
              entries[i].toText(),
              style: TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          );
  }
}
