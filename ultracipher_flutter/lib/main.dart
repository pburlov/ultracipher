import 'package:flutter/material.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/database_loaded.dart';
import 'package:ultracipher_flutter/src/local_store/local_store.dart';
import 'package:ultracipher_flutter/src/login.dart';

void main() async{
  WidgetsFlutterBinding.ensureInitialized();
  runApp(await buildApp());
}

/// Startet die App-Logik und liefert die Wurzel. Scheitert [UltracipherApp.init]
/// (z. B. der lokale Speicher ist nicht benutzbar), kommt eine schlichte
/// Fehlerseite statt eines weißen Bildschirms; ohne Speicher gäbe es sonst
/// keine Datenbanken und kein Speichern.
Future<Widget> buildApp() async {
  try {
    await UltracipherApp.instance.init();
  } catch (e) {
    // Nur feste Texte: ein OS-Fehler enthielte Pfade (und damit DB-Namen).
    print('Starting the app failed (${e.runtimeType})');
    return StartupErrorApp(
        message: e is LocalStoreException
            ? e.toString()
            : 'Starting the app failed');
  }
  return MyApp();
}

/// Fehlerseite des Starts ([buildApp]).
class StartupErrorApp extends StatelessWidget {
  final String message;

  const StartupErrorApp({Key? key, required this.message}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ultracipher',
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(message, textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ultracipher',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // Try running your application with "flutter run". You'll see the
        // application has a blue toolbar. Then, without quitting the app, try
        // changing the primarySwatch below to Colors.green and then invoke
        // "hot reload" (press "r" in the console where you ran "flutter run",
        // or simply save your changes to "hot reload" in a Flutter IDE).
        // Notice that the counter didn't reset back to zero; the application
        // is not restarted.
        primarySwatch: Colors.blue,
      ),
      home: ValueListenableBuilder(
        valueListenable: UltracipherApp.instance.loadedDatabase,
        builder: (context, value, child) {
          if(value == null) {
            return LoginScreen();
          }
          return DatabaseLoadedScreen(database: UltracipherApp.instance.loadedDatabase.value);
        },
      ),
    );
  }
}

