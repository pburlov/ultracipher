import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Ob die App im Browser laeuft. Testnaht: Tests setzen den Wert, die App
/// nicht. Im Web blockiert die Schluesselableitung den Haupt-Thread.
bool progressOnWeb = kIsWeb;

/// Hinweis fuer Fortschrittsbilder mit Schluesselableitung: im Browser dauert
/// sie etwa 10-20 s je Ableitung und die Seite reagiert dabei nicht; nativ
/// `null`. [derivations] ist die Zahl der Ableitungen hintereinander.
String? derivationHint({int derivations = 1}) {
  if (!progressOnWeb) return null;
  var range = '${10 * derivations}-${20 * derivations}';
  return 'In the browser this takes about $range seconds. The page may '
      'not respond in the meantime; please wait.';
}

/// Sperrschicht mit Fortschrittsanzeige: dunkle Barriere (nimmt jede Eingabe
/// darunter weg) und eine Karte mit Spinner und [title]. Wird über
/// [runWithProgress] als eigene Route gezeigt.
class ProgressScreen extends StatelessWidget {
  final String? title;

  /// Zusatzzeile unter dem Titel (z. B. Webhinweis), `null` = keine.
  final String? hint;

  const ProgressScreen({Key? key, this.title, this.hint}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: const Alignment(0, 0),
      children: [
        ModalBarrier(color: Colors.black26, dismissible: false),
        Center(
            child: Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                if (title != null)
                  Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(title!),
                  ),
                if (hint != null)
                  Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: 280),
                      child: Text(hint!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ),
              ],
            ),
          ),
        ))
      ],
    );
  }
}

/// Führt [operation] hinter einem [ProgressScreen] aus und gibt deren
/// Ergebnis zurück (oder wirft deren Fehler unverändert weiter, damit der
/// Aufrufer die Ausnahme-Typen unterscheiden kann).
///
/// Die Sperre ist eine eigene, nicht schließbare Route (Tippen daneben und
/// die Zurück-Taste tun nichts) und liegt über der ganzen App: solange die
/// Operation läuft, kann nichts bearbeitet werden. Sie verschwindet in jedem
/// Fall, auch bei einem Fehler. Der Navigator wird vor dem ersten await
/// geholt, der [context] bleibt danach unbenutzt.
Future<T> runWithProgress<T>(
    BuildContext context, Future<T> Function() operation,
    {String title = 'Processing...', String? hint}) async {
  var navigator = Navigator.of(context, rootNavigator: true);
  var route = PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: false,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (context, animation, secondaryAnimation) =>
        PopScope(canPop: false, child: ProgressScreen(title: title, hint: hint)),
  );
  navigator.push(route);
  try {
    // Im Web laeuft die Ableitung inline auf dem Haupt-Thread und friert die
    // Seite ein. Vorher muss die Sperre samt Hinweis wirklich gezeichnet sein:
    // erst das Frame abwarten, dann dem Browser einen Zeitgeber-Tick zum
    // Malen lassen. Nativ nicht noetig (Worker-Isolate).
    if (progressOnWeb) {
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return await operation();
  } finally {
    if (navigator.mounted && route.isActive) {
      navigator.removeRoute(route);
    }
  }
}
