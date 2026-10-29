// In-memory RemoteBackend for tests (no network, no GitHub).
//
// Stands in for a remote in the tests of core.dart's generic open/save/sync
// path (saveDatabase / syncNow), so that path can be
// exercised without a GitHub repository. Holds one blob and mirrors GitHub's
// optimistic-concurrency semantics: every stored state has a version (an
// incrementing "sha"), a read returns it, and a write must present the
// current one (null for a file that does not exist yet) or it fails with a
// RemoteConflictException.
//
// Test controls: failures to inject ([readFailure], [writeFailure],
// [deleteFailure], [conflictAtWrite], [beforeWrite]), gates to hold a call in
// flight ([readGate], [writeGate]), a simulated request timeout that leaves
// the write under way ([abandonWrites]), and counters ([readCount],
// [writeCount], [deleteCount], [committedWrites]). [seed] and [deleteFile] change the stored state
// without any check (what "another device did").
import 'dart:async';
import 'dart:typed_data';

import 'package:ultracipher_flutter/src/backend/remote_backend.dart';

class FakeRemoteBackend implements RemoteBackend {
  Uint8List? _bytes;
  String? _version;
  int _shaCounter = 0;

  /// Reads started (including failed ones).
  int readCount = 0;

  /// Writes started (including failed and conflicting ones).
  int writeCount = 0;

  /// Writes that actually changed the stored state (via [write] only, not
  /// [seed]).
  int committedWrites = 0;

  /// When set, every [read] throws this (after counting).
  Object? readFailure;

  /// When set, every [write] throws this (after counting and [beforeWrite]).
  Object? writeFailure;

  /// 1-based numbers of [write] calls (counted in [writeCount]) that fail with
  /// a [RemoteConflictException] even if the version matches.
  final Set<int> conflictAtWrite = {};

  /// When true, every [write] fails with a [RemoteConflictException].
  bool alwaysConflict = false;

  /// Called at the start of each [write] (after counting, before the version
  /// check) with the number of the write. Use it to land "another device's"
  /// change through [seed], so the version check really fails.
  void Function(int writeNumber)? beforeWrite;

  /// While set, [read] waits for it before looking at the stored state.
  Completer<void>? readGate;

  /// While set, [write] waits for it before touching the stored state.
  Completer<void>? writeGate;

  /// Deletes started (including failed and conflicting ones).
  int deleteCount = 0;

  /// When set, every [delete] throws this (after counting).
  Object? deleteFailure;

  /// Deletes that were started while a write was still under way (see
  /// [whenWritesSettled]).
  int deletesWhileWritePending = 0;

  /// Simulates the request timeout of the real backend (plan R3): [write]
  /// fails at once for the caller, but the write itself stays under way
  /// (held by [writeGate], if set) and may still land later.
  bool abandonWrites = false;

  /// Pessimistic stand-in for GitHub's unverified behaviour: a write WITH a
  /// version onto a missing file creates it instead of failing.
  bool createOnStaleVersionWhenMissing = false;

  int _pendingWrites = 0;
  Completer<void>? _settled;

  /// The blob as currently stored, or null if nothing was ever written (or
  /// the file was deleted).
  Uint8List? get storedBytes =>
      _bytes == null ? null : Uint8List.fromList(_bytes!);

  /// The version of the stored blob, or null if there is none.
  String? get storedVersion => _version;

  /// Puts [bytes] into the remote bypassing every check and counter, with a
  /// new version. For test setup and for "another device wrote".
  void seed(Uint8List bytes) {
    _bytes = Uint8List.fromList(bytes);
    _version = 'sha${_shaCounter++}';
  }

  /// Removes the file (the remote then answers like a 404: an empty read).
  void deleteFile() {
    _bytes = null;
    _version = null;
  }

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  Future<RemoteData> read(String name) async {
    readCount++;
    var gate = readGate;
    if (gate != null) {
      await gate.future;
    }
    var failure = readFailure;
    if (failure != null) {
      throw failure;
    }
    if (_bytes == null) {
      return RemoteData(bytes: Uint8List(0));
    }
    return RemoteData(bytes: Uint8List.fromList(_bytes!), version: _version);
  }

  @override
  Future<String?> write(String name, Uint8List bytes, {String? version}) {
    var number = ++writeCount;
    var landing = _pending(() => _write(number, bytes, version));
    if (abandonWrites) {
      landing.catchError((Object _) => null);
      return Future.error(RemoteBackendException('Timeout (injected)'));
    }
    return landing;
  }

  /// Counts [action] as under way until it ends (see [whenWritesSettled]).
  Future<T> _pending<T>(Future<T> Function() action) async {
    _pendingWrites++;
    try {
      return await action();
    } finally {
      if (--_pendingWrites == 0) {
        _settled?.complete();
        _settled = null;
      }
    }
  }

  Future<String?> _write(int number, Uint8List bytes, String? version) async {
    beforeWrite?.call(number);
    var gate = writeGate;
    if (gate != null) {
      await gate.future;
    }
    var failure = writeFailure;
    if (failure != null) {
      throw failure;
    }
    if (alwaysConflict || conflictAtWrite.contains(number)) {
      throw RemoteConflictException('Conflict (injected)', statusCode: 409);
    }
    var lenient =
        createOnStaleVersionWhenMissing && _version == null && version != null;
    if (version != _version && !lenient) {
      throw RemoteConflictException(
          _version == null
              ? 'The file does not exist but a version was given'
              : 'The version is missing or outdated',
          statusCode: _version == null ? 422 : 409);
    }
    _bytes = Uint8List.fromList(bytes);
    _version = 'sha${_shaCounter++}';
    committedWrites++;
    return _version;
  }

  /// Like GitHub: the version must match the stored one; a missing file is a
  /// conflict as well (GitHub's 404 on DELETE maps to it).
  @override
  Future<void> delete(String name, String version) {
    deleteCount++;
    if (_pendingWrites > 0) {
      deletesWhileWritePending++;
    }
    return _pending(() async {
      var failure = deleteFailure;
      if (failure != null) {
        throw failure;
      }
      if (_version == null || version != _version) {
        throw RemoteConflictException('Remote database changed since it was '
            'read',
            statusCode: _version == null ? 404 : 409);
      }
      deleteFile();
    });
  }

  @override
  Future<void> whenWritesSettled() {
    if (_pendingWrites == 0) {
      return Future.value();
    }
    return (_settled ??= Completer<void>()).future;
  }

  @override
  void close() {}
}
