import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Die gebuendelte Schrift fuer den Editor (view_entry.dart) muss die statische
// Regular-Datei sein: die variable Datei hatte Standardgewicht 200 (ExtraLight).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SourceCodePro ist als statische Schrift mit Gewicht 400 gebuendelt',
      () async {
    final data = await rootBundle
        .load('assets/fonts/source_code_pro/SourceCodePro-Regular.ttf');
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final view = ByteData.sublistView(bytes);
    final tables = <String, int>{};
    final numTables = view.getUint16(4);
    for (var i = 0; i < numTables; i++) {
      final at = 12 + 16 * i;
      final tag = String.fromCharCodes(bytes.sublist(at, at + 4));
      tables[tag] = view.getUint32(at + 8);
    }
    // usWeightClass steht bei Offset 4 der OS/2-Tabelle.
    expect(view.getUint16(tables['OS/2']! + 4), 400);
    // Keine variable Schrift (sonst Standardgewicht je nach fvar-Default).
    expect(tables.containsKey('fvar'), isFalse);
  });

  test('pubspec registriert SourceCodePro mit Gewicht 400', () async {
    final manifest = await rootBundle.loadString('FontManifest.json');
    expect(manifest, contains('"family":"SourceCodePro"'));
    expect(manifest, contains('"weight":400'));
  });
}
