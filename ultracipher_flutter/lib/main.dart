import 'package:flutter/material.dart';
import 'package:ultracipher_flutter/src/core.dart';
import 'package:ultracipher_flutter/src/database_loaded.dart';
import 'package:ultracipher_flutter/src/login.dart';

void main() async{
  WidgetsFlutterBinding.ensureInitialized();
  await UltracipherApp.instance.init();
  runApp(MyApp());
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

