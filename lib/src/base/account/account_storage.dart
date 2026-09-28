/// The account storage surface, as this product sees it.
///
/// The contract is `specs/platform/20-account-storage.md` and is not restated
/// here. What this file does is put that surface in Dart so the modules above
/// it can be written and tested — the shapes, the scopes, and the two ways a
/// write is refused.
///
/// **The server does not know what any of this means.** Bodies are bytes,
/// `contentType` is a label it stores and hands back, and `version` is an
/// opaque string to compare and never to parse. Everything that reads meaning
/// out of a body lives above this line.
///
/// This file names no platform library.
library;

import 'dart:typed_data';

/// Where a record lives.
///
/// A boundary rather than a folder — permission, quota, and what mirrors to
/// other devices are all decided here. Sealed and constructed only through
/// the named factories, so a scope is either one the contract defines or it
/// does not exist. A plain string would let a typo open a seventh scope that
/// nothing enforces.
sealed class StorageScope {
  const StorageScope();

  /// This product's shell. Named here because the product identifier is a
  /// property of the product, and the modules above should not each carry a
  /// literal that has to agree.
  static const StorageScope shell = _Shell(kStudioShellProduct);

  /// Account taste that crosses products — language, theme.
  ///
  /// Deliberately small. Moving a key up to common later is easy; splitting
  /// one back out touches every product already reading it.
  static const StorageScope common = _ShellCommon();

  /// Documents the person moves between apps. The only scope that crosses
  /// the isolation, which is why the person mediates it rather than the app.
  static const StorageScope shared = _Shared();

  /// Another product's shell — AppPlayer's, say. Readable here for the same
  /// reason a device can read another device: showing what exists is not the
  /// same as writing it.
  factory StorageScope.shellOf(String product) = _Shell;

  /// One app's data, wherever it was opened from. Which product opened it is
  /// not the app's concern.
  factory StorageScope.app(String appId) = _App;

  /// Knowledge the person accumulated, keyed by the bundle namespace from
  /// `07-knowledge-access.md`. Not what shipped inside a bundle, and not a
  /// derived index.
  factory StorageScope.knowledge(String scopeId) = _Knowledge;

  /// One device's own facts. **Single writer** — that device and no other,
  /// which is what removes conflict from this scope entirely.
  ///
  /// Enforced by the server. A client cannot enforce it, and one that assumed
  /// its own good behaviour would be trusting exactly the thing the rule
  /// exists to distrust.
  factory StorageScope.device(String deviceId) = _Device;

  /// A bundle this account made or sideloaded. Not one bought from Apps —
  /// that one is fetched from Apps by each device, because storing it here
  /// would be keeping a second copy of something already kept.
  factory StorageScope.bundle(String ref) = _Bundle;

  /// How the scope is addressed on the wire.
  String get wire;

  @override
  String toString() => wire;

  @override
  bool operator ==(Object other) => other is StorageScope && other.wire == wire;

  @override
  int get hashCode => wire.hashCode;
}

/// Studio's product identifier in account storage (`shell/studio`, platform
/// spec 20 §2.1).
const String kStudioShellProduct = 'studio';

class _ShellCommon extends StorageScope {
  const _ShellCommon();
  @override
  String get wire => 'shell/common';
}

class _Shell extends StorageScope {
  const _Shell(this.product) : assert(product != 'common');
  final String product;
  @override
  String get wire => 'shell/$product';
}

class _App extends StorageScope {
  const _App(this.appId);
  final String appId;
  @override
  String get wire => 'app/$appId';
}

class _Knowledge extends StorageScope {
  const _Knowledge(this.scopeId);
  final String scopeId;
  @override
  String get wire => 'knowledge/$scopeId';
}

class _Device extends StorageScope {
  const _Device(this.deviceId);
  final String deviceId;
  @override
  String get wire => 'device/$deviceId';
}

class _Bundle extends StorageScope {
  const _Bundle(this.ref);
  final String ref;
  @override
  String get wire => 'bundle/$ref';
}

class _Shared extends StorageScope {
  const _Shared();
  @override
  String get wire => 'shared';
}

/// What a listing says about a record without fetching it.
class RecordInfo {
  const RecordInfo({
    required this.key,
    required this.size,
    required this.version,
    required this.updatedAt,
  });

  final String key;
  final int size;

  /// Opaque. Compare it; never read anything out of it.
  final String version;
  final DateTime updatedAt;
}

/// A record and the version it was read at.
///
/// The version travels with the body because that pairing is what makes a
/// later conditional write meaningful — a version remembered separately from
/// what it described is a version that can go stale silently.
class StoredRecord {
  const StoredRecord({
    required this.body,
    required this.contentType,
    required this.version,
    required this.updatedAt,
  });

  final Uint8List body;

  /// A label for whoever reads the body. The server does not branch on it.
  final String contentType;

  final String version;
  final DateTime updatedAt;
}

/// What a write leaves behind: the version to hold for the next one.
class WriteReceipt {
  const WriteReceipt({required this.version, required this.updatedAt});

  final String version;
  final DateTime updatedAt;
}

/// What the account is using, and against what.
class StorageUsage {
  const StorageUsage({
    required this.used,
    required this.limit,
    required this.byScope,
    this.inlineCeiling = 0,
    this.maxBodyBytes = 0,
  });

  final int used;
  final int limit;

  /// By **family** — `shell`, `appState`, `knowledge`, `devices`, `bundles`,
  /// `shared` — not by scope.
  ///
  /// `app/<appId>` is dynamic, and an account may hold hundreds of them.
  /// Aggregating those one by one puts every app's save on a single counter,
  /// which is where the write contention then lives. Narrowing to a family
  /// and then reading `list` for the sizes answers the same question in two
  /// steps without that.
  final Map<String, int> byScope;

  /// The largest body [AccountStorage.put] takes inline.
  ///
  /// Reported rather than held as a client constant: a constant makes the
  /// client wrong first on the day the server changes it. Zero means the
  /// server did not say, which is how a fake with no ceiling reads.
  ///
  /// A caller does **not** branch on this. It is the boundary between the two
  /// ways the adapter moves a body, and the adapter picks. What it is good
  /// for above this line is explaining a cost — a body over the ceiling makes
  /// a round trip a small one does not.
  final int inlineCeiling;

  /// The largest body the surface accepts at all, by any route.
  ///
  /// Distinct from [inlineCeiling]: past the ceiling a body still gets in, it
  /// just travels differently. Past this it does not get in. Reported for the
  /// same reason the ceiling is — and because a caller that learns the limit
  /// only from the refusal has already spent the upload finding out.
  ///
  /// Zero means the server did not say. Do not read that as "no limit":
  /// treat it as unknown and let the refusal speak.
  final int maxBodyBytes;

  int get remaining => limit - used <= 0 ? 0 : limit - used;
  bool get isFull => used >= limit;
}

/// Somebody else wrote first.
///
/// Carries **the record as it now stands**, which is the whole point: without
/// it the client has to go read again to merge, and anything that changes in
/// between puts it back here.
///
/// This is not something to resolve at this layer. The layer that knows what
/// the body means does the merging, and where it cannot, it asks the person.
class VersionConflict implements Exception {
  const VersionConflict({
    required this.scope,
    required this.key,
    required this.current,
  });

  final StorageScope scope;
  final String key;

  /// What is there now, or null.
  ///
  /// Null in two cases, and they are different: the record was deleted out
  /// from under the write, or the body was too large to carry back. A caller
  /// that merges has to handle both by not merging — one has nothing to merge
  /// against, and the other lives in a scope where the content addresses
  /// itself and two writers write the same bytes.
  final StoredRecord? current;

  @override
  String toString() =>
      'VersionConflict($scope/$key): '
      '${current == null ? 'the record was deleted' : 'a newer version exists'}';
}

/// The account is full, and this is the write that did not fit.
///
/// Names the scope and key rather than reporting that saving failed. A person
/// told only that something failed cannot do anything about it.
class QuotaExceeded implements Exception {
  const QuotaExceeded({
    required this.scope,
    required this.key,
    required this.needed,
    required this.usage,
  });

  final StorageScope scope;
  final String key;

  /// Bytes this write would have added beyond what is left.
  final int needed;
  final StorageUsage usage;

  @override
  String toString() =>
      'QuotaExceeded: $scope/$key needs $needed more bytes '
      'than the ${usage.limit}-byte account has left';
}

/// Too big to hand over inline.
///
/// Not a failure to store — it is the surface saying which way this body has
/// to travel. A bundle body is megabytes; the alternative to refusing is
/// truncating, and a truncated bundle is a loss reported as a success.
class BodyTooLarge implements Exception {
  const BodyTooLarge({
    required this.scope,
    required this.key,
    required this.size,
    required this.ceiling,
  });

  final StorageScope scope;
  final String key;
  final int size;

  /// The limit that was passed, from [StorageUsage.maxBodyBytes].
  ///
  /// Not [StorageUsage.inlineCeiling] — passing that one is not a refusal,
  /// it only changes how the body travels.
  final int ceiling;

  @override
  String toString() =>
      'BodyTooLarge($scope/$key): $size bytes past the '
      '$ceiling-byte limit — this body is not accepted by any route';
}

/// The five surfaces, and nothing else.
///
/// Reads never throw for absence — a record that was never written is null,
/// and an empty scope lists empty. Writes throw for the two things a client
/// has to act on differently: [VersionConflict] and [QuotaExceeded].
abstract interface class AccountStorage {
  /// Records in [scope], optionally those whose key starts with [prefix].
  ///
  /// Bodies are not fetched. A listing exists so a client can decide what to
  /// fetch, and fetching everything to find out defeats that.
  Future<List<RecordInfo>> list(StorageScope scope, {String? prefix});

  /// The record, or null when nothing was ever written at [key].
  Future<StoredRecord?> get(StorageScope scope, String key);

  /// Write [body], and say what it is with [contentType].
  ///
  /// [ifMatch] is the version this write is based on. Omitting it overwrites
  /// unconditionally, which is right for a first write and for a person who
  /// has been asked and chose to force — and wrong everywhere else, because
  /// it is how a device that was offline erases an edit it never saw.
  ///
  /// Throws [VersionConflict] when [ifMatch] does not match,
  /// [QuotaExceeded] when the account has no room, and [BodyTooLarge] when
  /// the body is past [StorageUsage.maxBodyBytes].
  ///
  /// **Size is not the caller's branch.** A body over
  /// [StorageUsage.inlineCeiling] travels by transfer ticket instead of
  /// inline, and that happens below this line — the caller passes bytes and
  /// gets a receipt either way. Choosing the call by size would put the same
  /// conditional in every caller, and each one would get it slightly
  /// differently wrong.
  ///
  /// **The receipt means the record exists, not that the bytes arrived.** For
  /// a transferred body the server issues the version when the object lands,
  /// so this call does not return at upload time — it returns when there is a
  /// version. If none is issued the write **failed**; treating the completed
  /// upload as success hands the caller a version that does not exist yet,
  /// and the next conditional write is the thing that breaks.
  ///
  /// An oversized body is refused rather than truncated: a bundle body is
  /// megabytes, and a silent truncation reports a loss as a success.
  Future<WriteReceipt> put(
    StorageScope scope,
    String key,
    Uint8List body, {
    required String contentType,
    String? ifMatch,
  });

  /// Remove [key]. Absent is not an error — it is the state the caller wanted.
  ///
  /// Throws [VersionConflict] when [ifMatch] is given and does not match, so
  /// a delete cannot quietly discard an edit made since the read.
  Future<void> delete(StorageScope scope, String key, {String? ifMatch});

  /// What the account is using.
  Future<StorageUsage> usage();
}
