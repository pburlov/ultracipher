import 'local_store.dart';

/// Plattformen ohne Speicher (Web folgt in einem eigenen Schritt).
Future<LocalDatabaseStore> createPlatformStore() async =>
    throw UnsupportedError('No local database store for this platform');
