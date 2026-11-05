// Waehlt die Speicher-Implementierung je Plattform. Reihenfolge io vor
// js_interop (auf der VM ist io da); nicht dart.library.html, das es unter
// dart2wasm nicht gibt. Der Web-Zweig zeigt vorerst auf den Stub.
export 'local_store_stub.dart' if (dart.library.io) 'local_store_io.dart';
