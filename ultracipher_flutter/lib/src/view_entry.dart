import 'package:flutter/material.dart';
import 'package:ultracipher_flutter/src/model/model.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:intl/intl.dart';

import 'commons.dart';

class EntryViewScreen extends StatefulWidget {
  final VersionedEntry? entry;

  const EntryViewScreen({Key? key, this.entry}) : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return _EntryViewWidgetState();
  }
}

class _EntryViewWidgetState extends State<EntryViewScreen> {
  VersionedEntry? entry;
  int? currentVersionIndex;
  var editing = false;
  var labelController = TextEditingController();
  var tagsController = TextEditingController();
  var contentController = TextEditingController();
  final labelFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    entry = widget.entry;
    currentVersionIndex = entry != null ? 0 : -1;
    editing = entry == null;
    _initTextControllers();
    contentController.addListener(() {setState(() { });});
    tagsController.addListener(() {setState(() { });});
    labelController.addListener(() {setState(() { });});
  }


  @override
  void dispose() {
    super.dispose();
    contentController.dispose();
    tagsController.dispose();
    labelController.dispose();
    labelFocus.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var dateFormat = DateFormat.yMMMd().add_Hms();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: editing ? Colors.red : null,
        title: editing
            ? Text(
                'Edit',
                style: TextStyle(color: Colors.black),
              )
            : null,
        actions: editing
            ? [
                Padding(
                    padding: EdgeInsets.all(3),
                    child: IconButton(
                        // color: Colors.green,
                        onPressed: _commitEdit,
                        icon: Icon(Icons.check_circle))),
                Padding(
                    padding: EdgeInsets.all(3),
                    child: IconButton(
                        // color: Colors.red,
                        onPressed: _discardChanges,
                        icon: Icon(Icons.cancel_rounded)))
              ]
            : [
                if (currentVersionIndex! < 1) //Nur neueste Version darf editiert werden
                  Padding(padding: EdgeInsets.all(3), child: IconButton(onPressed: _startEdit, icon: Icon(Icons.edit))),
                Padding(padding: EdgeInsets.all(3), child: IconButton(onPressed: _deleteEntry, icon: Icon(Icons.delete_forever)))
              ],
      ),
      body: WillPopScope(
        onWillPop: () => editing ? _discardChanges().then((value) => value!) : Future.value(true),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Text('Create time: '),
                if (entry != null && entry!.versions.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.all(3),
                    child: DropdownButton(
                      value: currentVersionIndex,
                      icon: const Icon(Icons.arrow_downward),
                      iconSize: 24,
                      elevation: 16,
                      style: const TextStyle(color: Colors.deepPurple),
                      underline: Container(
                        height: 2,
                        color: Colors.black,
                      ),
                      onChanged: (int? newValue) {
                        setState(() {
                          currentVersionIndex = newValue;
                          _initTextControllers();
                        });
                      },
                      items: [
                        for (int i = 0; i < entry!.versions.length; i++)
                          DropdownMenuItem<int>(
                            value: i,
                            child: Text(dateFormat.format(entry!.versions[i].createDateTime.toLocal())),
                          )
                      ],
                    ),
                  ),
              ],
            ),
            Padding(
                padding: EdgeInsets.all(3),
                child: TextField(
                  decoration: InputDecoration(
                    filled: true,
                    labelText: 'Label',
                    border: OutlineInputBorder(),
                  ),
                  readOnly: !editing,
                  focusNode: labelFocus,
                  // Neuer Eintrag: Cursor gleich im Label (auch auf dem Handy).
                  autofocus: widget.entry == null,
                  controller: labelController,
                )),
            Padding(
                padding: EdgeInsets.all(3),
                child: TextField(
                  decoration: InputDecoration(
                    filled: true,
                    labelText: 'Tags',
                    border: OutlineInputBorder(),
                  ),
                  readOnly: !editing,
                  controller: tagsController,
                )),
            Expanded(
                child: Padding(
                    padding: EdgeInsets.all(3),
                    child: TextField(
                      textAlignVertical: TextAlignVertical.top,
                      enableSuggestions: false,
                      autocorrect: false,
                      expands: true,
                      decoration: InputDecoration(
                        filled: true,
                        border: OutlineInputBorder(),
                        labelText: 'Content',
                      ),
                      readOnly: !editing,
                      controller: contentController,
                      maxLines: null,
                      minLines: null,
                      style: TextStyle(fontFamily: 'SourceCodePro'),
                    ))),
            if (editing)
              Padding(
                  padding: EdgeInsets.all(5),
                  child: _buildGeneratePassphraseWidget(),)
          ],
        ),
      ),
    );
  }

  void _initTextControllers() {
    if (entry != null && currentVersionIndex! > -1 && currentVersionIndex! < entry!.versions.length) {
      var currentVersion = entry!.versions[currentVersionIndex!];
      labelController.text = currentVersion.label;
      tagsController.text = currentVersion.tags;
      contentController.text = currentVersion.content;
    } else {}
  }

  void _commitEdit() async {
    var database = UltracipherApp.instance.loadedDatabase.value!;
    var version = Entry(
        label: labelController.text,
        tags: tagsController.text,
        content: contentController.text);
    // Ueber die Datenbank, per id: der Eintrag kann seit dem Oeffnen durch
    // einen Sync aus der Datenbank verschwunden sein (siehe addVersion).
    var previous = entry;
    entry = database.addVersion(previous, version);
    currentVersionIndex = 0;
    var result = await showProgressDialog(context, UltracipherApp.instance.saveDatabase(), 'Saving...');
    setState(() {
      // null (dialog dismissed without a result) is "not successful", not a
      // crash - same as the plain false case.
      if (result ?? false) {
        editing = false;
      } else if (identical(UltracipherApp.instance.loadedDatabase.value, database)) {
        // saveDatabase wartet nicht mehr auf das Netz: es scheitert nur noch
        // lokal (Cache nicht beschreibbar, keine Sitzung). Dann ist nichts
        // gespeichert, genau die eigene neue Version wird wieder entfernt
        // (ein neuer Eintrag verschwindet damit ganz).
        // Netzfehler zeigt der Sync-Status, sie fuehren hier nie hin.
        // Ist die Datenbank nicht mehr die geoeffnete (Sitzung beendet oder
        // eine andere geoeffnet), wird nichts zurueckgenommen. Gegen den
        // Namenswechsel (Plan §10) schuetzt das NICHT: der Passphrase-Wechsel
        // behaelt dasselbe Datenbankobjekt. Dort schuetzt die Sperre ueber der
        // ganzen App ([runWithProgress]): waehrend des Wechsels kann nichts
        // gespeichert werden.
        database.removeVersion(entry!, version);
        entry = previous;
      }
    });
  }

  Future<bool?> _discardChanges() {
    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Discard changes'),
          content: Text('Discard changes?'),
          actions: [
            TextButton(
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.all<Color>(Colors.green),
                  foregroundColor: WidgetStateProperty.all<Color>(Colors.white),
                ),
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel')),
            TextButton(
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.all<Color>(Colors.red),
                  foregroundColor: WidgetStateProperty.all<Color>(Colors.white),
                ),
                onPressed: () {
                  Navigator.of(context).pop(true);
                  _discardConfirmed();
                },
                child: Text('Discard changes')),
          ],
        );
      },
    );
  }

  void _startEdit() {
    setState(() {
      editing = true;
    });
    // Erst nach dem Neuaufbau (Feld ist dann nicht mehr readOnly) fokussieren.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && editing) labelFocus.requestFocus();
    });
  }

  void _deleteEntry() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Delete entry'),
          content: Text('Are you sure?'),
          actions: [
            TextButton(
              onPressed: _deleteCancel,
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.all<Color>(Colors.green),
                foregroundColor: WidgetStateProperty.all<Color>(Colors.white),
              ),
              child: Text('Cancel'),
            ),
            TextButton(
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.all<Color>(Colors.red),
                  foregroundColor: WidgetStateProperty.all<Color>(Colors.white),
                ),
                onPressed: () {
                  Navigator.of(context).pop();
                  _deleteConfirmed();
                },
                child: Text('Delete')),
          ],
        );
      },
    );
  }

  void _deleteCancel() {
    Navigator.of(context).pop();
  }

  Future<void> _deleteConfirmed() async {
    if (entry != null) {
      var database = UltracipherApp.instance.loadedDatabase.value!;
      var deleted = entry!;
      var deletionsBefore = database.deletions;
      database.deleteEntry(deleted);
      var result = await showProgressDialog(context, UltracipherApp.instance.saveDatabase(), 'Saving...');
      // null (dialog dismissed without a result) is "not successful", not a
      // crash - same as the plain false case.
      if (result ?? false) {
        //Zur Suchmaske zurueckkehren
        Navigator.of(context).pop();
      } else if (identical(UltracipherApp.instance.loadedDatabase.value, database) &&
          database.getEntryWhitId(deleted.id) == null) {
        // Wie bei _commitEdit: saveDatabase scheitert nur lokal. Dann ist
        // nichts gespeichert, und die Loeschung wird zurueckgenommen (Eintrag
        // wieder da, id nicht mehr in der Loeschliste), sonst nimmt sie der
        // naechste Speichervorgang ungefragt mit.
        database.restoreDeletions(deletionsBefore);
        database.addEntry(entry: deleted);
        if (mounted) setState(() {});
      }
    }
  }

  void _discardConfirmed() {
    if (widget.entry == null) {
      //New entry mode. Back to list of entries
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      editing = false;
      _initTextControllers();
    });
  }

  Row _buildGeneratePassphraseWidget() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        ElevatedButton(
            onPressed: contentController.selection.start > -1 ? () {
              final psw = UltracipherApp.generatePassphrase();
              final text = contentController.text;
              final textSelection = contentController.selection;
              final newText = text.replaceRange(
                textSelection.start,
                textSelection.end,
                psw,
              );
              final myTextLength = psw.length;
              contentController.text = newText;
              contentController.selection = textSelection.copyWith(
                baseOffset: textSelection.start + myTextLength,
                extentOffset: textSelection.start + myTextLength,
              );
              // contentController.
            } : null,
            child: Text('Generate passphrase'))
      ],
    );
  }
}
