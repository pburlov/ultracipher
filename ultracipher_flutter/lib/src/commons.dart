import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:ultracipher_flutter/src/backend/remote_backend.dart';
import 'package:ultracipher_flutter/src/core.dart';

Future<bool?> showProgressDialog(
  BuildContext context,
  Future future, [
  String label = 'Processing...',
]) {
  // Der FutureBuilder hört erst beim ersten Bauen des Dialogs zu. Scheitert
  // [future] vorher (z. B. ein lokales Speichern, das ohne Ableitung nur noch
  // Mikrosekunden dauert), wäre der Fehler "unbehandelt". Der Fehler wird hier
  // als behandelt markiert; der FutureBuilder zeigt ihn weiterhin an.
  future.then<void>((_) {}, onError: (Object _) {});
  // Der Builder läuft mehr als einmal; geschlossen wird genau einmal.
  var closing = false;
  return showDialog<bool?>(
    context: context,
    // Not dismissible: tapping outside must not let the caller re-trigger
    // the same operation (e.g. changing the passphrase) while the Future backing
    // this dialog is still in flight.
    barrierDismissible: false,
    builder: (context) {
      return PopScope(
        // Block the Android back button too, for the same reason.
        canPop: false,
        child: FutureBuilder(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return AlertDialog(
                title: Icon(
                  Icons.warning,
                  color: Colors.redAccent,
                ),
                content: Text(snapshot.error.toString()),
                actions: [
                  IconButton(
                    icon: Icon(Icons.check_circle),
                    onPressed: () {
                      Navigator.of(context).pop(false);
                    },
                  )
                ],
              );
            }
            if (snapshot.hasData && !closing) {
              // Ohne Fehler, Dialog schliessen. Nicht im Builder: ein pop
              // mitten im Aufbau meldet "setState() during build". Nach dem
              // Frame, und nur wenn der Dialog noch da ist.
              closing = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) Navigator.of(context).pop(true);
              });
            }
            return Center(
                // Mindestgroesse statt fester Groesse: mit grosser Schrift
                // wuerde der Text sonst aus der Karte laufen.
                child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minWidth: 100, minHeight: 100),
                    child: Card(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Padding(
                            padding: EdgeInsets.all(5),
                            child: CircularProgressIndicator(),
                          ),
                          Padding(
                            padding: EdgeInsets.all(5),
                            child: Text(label),
                          )
                        ],
                      ),
                    )));
          },
        ),
      );
    },
  );
}

class PasswordField extends StatefulWidget {
  final TextEditingController? textController;
  final String label;
  final Color? fillColor;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  const PasswordField({
    Key? key,
    this.textController, this.label = 'Passphrase', this.fillColor,
    this.textInputAction, this.onSubmitted, this.autofocus = false,
  }) : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return _PasswordFieldState();
  }
}


class _PasswordFieldState extends State<PasswordField> {
  bool _obscuredText = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.textController,
      autofocus: widget.autofocus,
      obscureText: _obscuredText,
      // Ein Passwort gehoert weder in die Autokorrektur noch in Vorschlaege.
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        border: OutlineInputBorder(),
        filled: true,
        fillColor: widget.fillColor,
        suffixIcon: GestureDetector(
          dragStartBehavior: DragStartBehavior.down,
          onTap: () {
            setState(() {
              _obscuredText = !_obscuredText;
            });
          },
          child: Icon(_obscuredText ? Icons.visibility : Icons.visibility_off),
        ),
      ),
    );
  }
}

/// Text für einen Fehler im Dialog. Nur Meldungen, die bekanntermaßen weder
/// Passphrase, Token noch Inhalte enthalten (Texte der Kern-API, der Backends
/// und einfache Strings); bei allem anderen nur der Typ.
String describeError(Object error) {
  if (error is String) return error;
  if (error is RemoteBackendException ||
      error is NoLocalDatabaseException ||
      error is LocalDatabaseExistsException ||
      error is LocalDatabaseUnreadableException ||
      error is GithubFileMissingException) {
    return error.toString();
  }
  return 'Something went wrong (${error.runtimeType})';
}

/// Einfacher Hinweis-Dialog mit einem OK-Knopf.
Future<void> showMessageDialog(BuildContext context, String title,
    String message) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: Text('OK')),
      ],
    ),
  );
}

/// Ob [text] ein Zeichen ausserhalb von ASCII enthaelt (Umlaute, Akzente ...).
bool hasNonAscii(String text) => text.codeUnits.any((c) => c > 0x7F);

/// Rueckfrage vor einer neuen Passphrase mit Nicht-ASCII-Zeichen: dieselben
/// Zeichen koennen auf anderen Geraeten/Tastaturen anders eingegeben werden
/// (Unicode-Normalisierung), die Datenbank liesse sich dort nicht oeffnen.
/// Gibt `true` zurueck, wenn der User trotzdem fortfahren will.
Future<bool> confirmNonAsciiPassphrase(BuildContext context) async {
  var proceed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Non-ASCII characters in the passphrase'),
      content: Text('The passphrase contains characters beyond plain ASCII, '
          'for example umlauts or accents. Such characters can be entered '
          'in different ways on other devices or keyboards (Unicode '
          'normalisation). The database would then not open there, and the '
          'passphrase cannot be recovered.\n\n'
          'Continue only if you can always enter it exactly the same way; '
          'a passphrase of plain ASCII characters is safer.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Continue')),
      ],
    ),
  );
  return proceed == true;
}
