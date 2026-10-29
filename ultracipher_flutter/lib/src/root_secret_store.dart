import 'dart:typed_data';

/// Haken für einen späteren Secure-Storage-Ausbau (Spezifikation §3.5). In v1
/// gibt es keine Implementierung und nichts ist angebunden: kein Cache, `R`
/// steht nie in SharedPreferences.
///
/// Ein späterer Ausbau legt `R` (nie `K_A`, `K_S` oder einen anderen
/// Zwischenwert, §2.4) unter dem Datenbanknamen in den OS-Schlüsselspeicher,
/// hinter Biometrie. Das setzt voraus, dass Keychain/Keystore den Wert
/// schützt, und ist eine Entscheidung des späteren Projekts.
abstract class RootSecretStore {
  Future<Uint8List?> read(String name);
  Future<void> write(String name, Uint8List root);
  Future<void> delete(String name);
}
