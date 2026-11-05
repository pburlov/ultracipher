import 'local_store.dart';

/// Plattformen ohne Speicher.
Future<LocalDatabaseStore> createPlatformStore() async =>
    throw UnsupportedError('No local database store for this platform');
