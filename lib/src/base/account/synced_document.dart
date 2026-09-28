/// One account record, kept in step across devices.
///
/// This is the part of MOD-SYNC that every owner module sits on: hold the
/// version a value was read at, write against it, and when somebody wrote
/// first, hand the two versions to whoever knows what they mean.
///
/// **It never decides a merge.** The server cannot, because bodies are opaque
/// to it; this layer cannot either, because they are opaque to it too. A layer
/// that guessed would be "last write wins" wearing a different name — and the
/// cost of that lands on the device that was offline longest, whose return
/// erases edits it never saw.
///
/// So a merge is supplied by the owner, and an owner that cannot merge says
/// so. Then the person is asked. That is the whole ladder, and there is no
/// rung below it where something quietly picks.
library;

import 'dart:typed_data';

import 'account_storage.dart';

/// Turn a value into a body and back.
///
/// Owned by the module that knows the format, which is the same module that
/// knows how to merge it — the two always travel together.
class DocumentCodec<T> {
  const DocumentCodec({
    required this.encode,
    required this.decode,
    required this.contentType,
  });

  final Uint8List Function(T value) encode;
  final T Function(StoredRecord record) decode;
  final String contentType;
}

/// Reconcile two versions of a value that were written from different places.
///
/// [base] is what both sides started from — null when neither did, which is
/// two devices creating the same record independently. Returning null means
/// **this cannot be merged**, and the person is asked; it does not mean "keep
/// mine".
typedef MergeDocument<T> =
    T? Function({required T? base, required T mine, required T theirs});

/// Both versions, and nobody left to decide between them.
///
/// Thrown when the owner's merge declined. Carries everything needed to put
/// the choice in front of the person — the two values and what they were
/// about — because an exception that only said "conflict" would force the UI
/// to go and read again, racing the same write that caused this.
class MergeNeedsPerson<T> implements Exception {
  const MergeNeedsPerson({
    required this.scope,
    required this.key,
    required this.base,
    required this.mine,
    required this.theirs,
  });

  final StorageScope scope;
  final String key;
  final T? base;
  final T mine;
  final T theirs;

  @override
  String toString() =>
      'MergeNeedsPerson($scope/$key): the owner could not reconcile the two '
      'versions';
}

/// A conflict on a record only one writer was ever supposed to touch.
///
/// `device/<deviceId>` is single-writer, which is what removes merging from
/// that axis entirely. A conflict there does not mean two edits need
/// reconciling; it means the rule was broken, and merging would paper over
/// the fact that some other device is writing where it must not.
class SingleWriterViolated implements Exception {
  const SingleWriterViolated({required this.scope, required this.key});

  final StorageScope scope;
  final String key;

  @override
  String toString() =>
      'SingleWriterViolated($scope/$key): this record has one writer by '
      'contract, and something else wrote it';
}

/// A write kept losing races.
///
/// Retrying forever would hide a record being written in a loop by something
/// else. Giving up says which record, so the loop can be found.
class SyncGaveUp implements Exception {
  const SyncGaveUp({
    required this.scope,
    required this.key,
    required this.attempts,
  });

  final StorageScope scope;
  final String key;
  final int attempts;

  @override
  String toString() =>
      'SyncGaveUp($scope/$key): still conflicting after $attempts attempts';
}

/// One record, with the version it was last seen at.
class SyncedDocument<T> {
  SyncedDocument({
    required AccountStorage storage,
    required this.scope,
    required this.key,
    required DocumentCodec<T> codec,
    required MergeDocument<T> merge,
    this.maxAttempts = 5,
  }) : _storage = storage,
       _codec = codec,
       _merge = merge;

  /// A record with exactly one writer by contract — `device/<deviceId>`.
  ///
  /// No merge is supplied because there is nothing to merge: a conflict here
  /// is a broken rule, not a disagreement, and it is reported as one.
  SyncedDocument.singleWriter({
    required AccountStorage storage,
    required this.scope,
    required this.key,
    required DocumentCodec<T> codec,
  }) : _storage = storage,
       _codec = codec,
       _merge = null,
       maxAttempts = 1;

  final AccountStorage _storage;
  final StorageScope scope;
  final String key;
  final DocumentCodec<T> _codec;
  final MergeDocument<T>? _merge;

  /// How many times a write may lose the race before giving up.
  final int maxAttempts;

  String? _version;

  /// The value as last read or written, or null before either.
  ///
  /// Held so a merge has a base — without it, three-way merges become
  /// two-way, and a two-way merge cannot tell an addition on one side from a
  /// deletion on the other.
  T? _synced;

  /// The version this document is holding, if any. For diagnostics.
  String? get version => _version;

  /// What was last agreed with the server.
  T? get synced => _synced;

  /// Read the record.
  ///
  /// Null when nothing has been written yet, which is the ordinary first
  /// state and not a failure.
  Future<T?> load() async {
    final record = await _storage.get(scope, key);
    if (record == null) {
      _version = null;
      _synced = null;
      return null;
    }
    _version = record.version;
    _synced = _codec.decode(record);
    return _synced;
  }

  /// Write [next], reconciling with whatever arrived since [load].
  ///
  /// Returns what was actually stored, which is [next] when nobody else wrote
  /// and the merged value when somebody did — the caller needs to know which,
  /// because what is on screen has to become what is in the account.
  ///
  /// Throws [MergeNeedsPerson] when the owner declines a merge,
  /// [SingleWriterViolated] on a single-writer record, [SyncGaveUp] after
  /// [maxAttempts], and [QuotaExceeded] when the account is full.
  Future<T> save(T next) async {
    var mine = next;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final receipt = await _storage.put(
          scope,
          key,
          _codec.encode(mine),
          contentType: _codec.contentType,
          ifMatch: _version,
        );
        _version = receipt.version;
        _synced = mine;
        return mine;
      } on VersionConflict catch (conflict) {
        final merge = _merge;
        if (merge == null) {
          throw SingleWriterViolated(scope: scope, key: key);
        }

        final current = conflict.current;
        if (current == null) {
          // Deleted out from under us. There is nothing to reconcile with, so
          // the write becomes a first write rather than a lost one.
          _version = null;
          _synced = null;
          continue;
        }

        final theirs = _codec.decode(current);
        final merged = merge(base: _synced, mine: mine, theirs: theirs);
        if (merged == null) {
          throw MergeNeedsPerson<T>(
            scope: scope,
            key: key,
            base: _synced,
            mine: mine,
            theirs: theirs,
          );
        }

        // Retry against what is actually there now, not against what we
        // thought was there — otherwise the next attempt loses the same race.
        _version = current.version;
        _synced = theirs;
        mine = merged;
      }
    }

    throw SyncGaveUp(scope: scope, key: key, attempts: maxAttempts);
  }

  /// Take the value the person chose and make it the account's.
  ///
  /// For after [MergeNeedsPerson]. Unconditional on purpose — the choice was
  /// already made with both versions in view, and re-checking would only
  /// re-ask a question that was just answered.
  Future<T> resolveAs(T chosen) async {
    final receipt = await _storage.put(
      scope,
      key,
      _codec.encode(chosen),
      contentType: _codec.contentType,
    );
    _version = receipt.version;
    _synced = chosen;
    return chosen;
  }

  /// Remove the record, and forget the version.
  Future<void> delete() async {
    await _storage.delete(scope, key, ifMatch: _version);
    _version = null;
    _synced = null;
  }
}
