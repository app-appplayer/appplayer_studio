/// An account storage that keeps the contract but not the data.
///
/// The server that will implement `specs/platform/20-account-storage.md` does
/// not exist yet, and the modules above this line — shell layout, the install
/// list, merging — cannot be written against nothing. So this one keeps every
/// rule the contract states and holds the records in a map.
///
/// **It keeps the rules that are hard, not the ones that are easy.** Version
/// conflict returns the current body along with the refusal. A full account
/// refuses writes and keeps serving reads. Scopes cannot see each other. Those
/// are the behaviours the layers above are written against, and a fake that
/// only stored and returned would let all of them be got wrong.
///
/// What it is not: durable, shared, or a second source of truth. When the
/// server exists this is replaced by an implementation that talks to it, and
/// the modules above should not be able to tell — which is the test.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'account_storage.dart';

/// Records in a map, with the contract's rules enforced over them.
class InMemoryAccountStorage implements AccountStorage {
  InMemoryAccountStorage({
    this.limit = _defaultLimit,
    this.inlineCeiling = 0,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Five gigabytes, the subscription's allowance. A caller that wants to see
  /// what a full account does passes something small.
  static const int _defaultLimit = 5 * 1024 * 1024 * 1024;

  final int limit;

  /// The largest body taken inline; zero means no ceiling.
  ///
  /// Zero by default because the layers above are written against small
  /// records, and a fake that imposed a ceiling nobody asked for would fail
  /// them for a reason the real surface would not.
  final int inlineCeiling;

  final DateTime Function() _clock;

  final Map<String, Map<String, _Entry>> _byScope =
      <String, Map<String, _Entry>>{};

  /// Versions are issued, never derived from the body.
  ///
  /// A hash would collide with itself: writing a value, changing it, and
  /// changing it back would produce a version that matches a stale `ifMatch`,
  /// and the write it should have refused would go through.
  int _nextVersion = 1;

  @override
  Future<List<RecordInfo>> list(StorageScope scope, {String? prefix}) async {
    final entries = _byScope[scope.wire];
    if (entries == null) return const <RecordInfo>[];
    final keys =
        entries.keys
            .where((key) => prefix == null || key.startsWith(prefix))
            .toList()
          ..sort();
    return <RecordInfo>[
      for (final key in keys)
        RecordInfo(
          key: key,
          size: entries[key]!.body.length,
          version: entries[key]!.version,
          updatedAt: entries[key]!.updatedAt,
        ),
    ];
  }

  @override
  Future<StoredRecord?> get(StorageScope scope, String key) async {
    final entry = _byScope[scope.wire]?[key];
    if (entry == null) return null;
    return StoredRecord(
      // Copied, so a caller that mutates what it read does not reach back in
      // and change what is stored without a write.
      body: Uint8List.fromList(entry.body),
      contentType: entry.contentType,
      version: entry.version,
      updatedAt: entry.updatedAt,
    );
  }

  @override
  Future<WriteReceipt> put(
    StorageScope scope,
    String key,
    Uint8List body, {
    required String contentType,
    String? ifMatch,
  }) async {
    if (inlineCeiling > 0 && body.length > inlineCeiling) {
      // Before the conflict check on purpose: a body that cannot travel this
      // way does not travel this way whoever wrote last, and reporting a
      // conflict first would send the caller off to merge something it then
      // still could not store.
      throw BodyTooLarge(
        scope: scope,
        key: key,
        size: body.length,
        ceiling: inlineCeiling,
      );
    }

    final entries = _byScope.putIfAbsent(scope.wire, () => <String, _Entry>{});
    final existing = entries[key];

    if (ifMatch != null && ifMatch != existing?.version) {
      throw VersionConflict(
        scope: scope,
        key: key,
        current:
            existing == null
                ? null
                : StoredRecord(
                  body: Uint8List.fromList(existing.body),
                  contentType: existing.contentType,
                  version: existing.version,
                  updatedAt: existing.updatedAt,
                ),
      );
    }

    // A rewrite pays only for what it adds — otherwise saving a document
    // twice would cost twice, and an account would fill up without anything
    // new being kept.
    final delta = body.length - (existing?.body.length ?? 0);
    final current = await usage();
    if (delta > 0 && current.used + delta > limit) {
      throw QuotaExceeded(
        scope: scope,
        key: key,
        needed: current.used + delta - limit,
        usage: current,
      );
    }

    final version = 'v${_nextVersion++}';
    final now = _clock();
    entries[key] = _Entry(
      body: Uint8List.fromList(body),
      contentType: contentType,
      version: version,
      updatedAt: now,
    );
    return WriteReceipt(version: version, updatedAt: now);
  }

  @override
  Future<void> delete(StorageScope scope, String key, {String? ifMatch}) async {
    final entries = _byScope[scope.wire];
    final existing = entries?[key];

    if (ifMatch != null && ifMatch != existing?.version) {
      throw VersionConflict(
        scope: scope,
        key: key,
        current:
            existing == null
                ? null
                : StoredRecord(
                  body: Uint8List.fromList(existing.body),
                  contentType: existing.contentType,
                  version: existing.version,
                  updatedAt: existing.updatedAt,
                ),
      );
    }

    entries?.remove(key);
  }

  @override
  Future<StorageUsage> usage() async {
    final byScope = <String, int>{};
    for (final scope in _byScope.entries) {
      final total = scope.value.values.fold<int>(
        0,
        (sum, entry) => sum + entry.body.length,
      );
      if (total > 0) byScope[scope.key] = total;
    }
    return StorageUsage(
      used: byScope.values.fold<int>(0, (sum, bytes) => sum + bytes),
      limit: limit,
      byScope: Map<String, int>.unmodifiable(byScope),
      inlineCeiling: inlineCeiling,
    );
  }

  /// Everything stored, for a test that wants to look without going through
  /// the surface. Not part of [AccountStorage] — nothing in the product may
  /// depend on it.
  Map<String, List<String>> get contents => <String, List<String>>{
    for (final scope in _byScope.entries)
      if (scope.value.isNotEmpty)
        scope.key: (scope.value.keys.toList()..sort()),
  };
}

class _Entry {
  const _Entry({
    required this.body,
    required this.contentType,
    required this.version,
    required this.updatedAt,
  });

  final Uint8List body;
  final String contentType;
  final String version;
  final DateTime updatedAt;
}

/// Encode [value] as a JSON body, with the label to store it under.
///
/// Here because every module above stores JSON and each writing its own
/// `utf8.encode(jsonEncode(...))` is how two of them end up disagreeing about
/// the content type.
({Uint8List body, String contentType}) jsonBody(Object? value) => (
  body: utf8.encode(jsonEncode(value)),
  contentType: 'application/json',
);

/// Read a JSON body back.
///
/// Throws when the bytes are not the JSON they were labelled as, rather than
/// answering null — null is what an absent record reads as, and a corrupt one
/// is not absent.
Object? decodeJsonBody(StoredRecord record) =>
    jsonDecode(utf8.decode(record.body));
