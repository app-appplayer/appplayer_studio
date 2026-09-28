/// `host.kb` wiring shared by every bundle activation in this host.
///
/// `host.kb` state is the kernel's: records live in the kernel key/value
/// store under `app/<appId>/kb/<key>` through one [mk.KvKbRecordStore]
/// (bundle spec 04_Tools §4.8.1, platform 20 §2.1.2). Bundle tabs and plugin
/// bundles share this one instance, so a key has one lock and one data set
/// whichever way the bundle was activated.
///
/// The app identity is the host's to decide: `bundle:<manifest.id>` unless
/// the host knows the app came from a marketplace listing ([appIdOf]).
///
/// The studio's former per-bundle `DomainStorage` files are imported **once
/// per app** — a marker in the key/value store records that the import ran.
/// Importing on every activation would bring back a key the bundle deleted,
/// because a deleted key reads as absent and the importer fills absent keys.
/// The old files are never deleted or overwritten.
library;

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;

class StudioKbWiring {
  StudioKbWiring({
    required mk.KvStoragePort kv,
    this.engine,
    // ignore: deprecated_member_use
    this.legacy,
    String? Function(mb.McpBundle bundle)? appIdOf,
    this.account,
  }) : _kv = kv,
       records = mk.KvKbRecordStore(kv),
       _appIdOf = appIdOf;

  final mk.KvStoragePort _kv;

  /// The device record store — every activation's while no account is
  /// syncing.
  final mk.KbRecordStore records;

  /// The account's `kb` records while this device syncs, null otherwise
  /// (platform spec 20 §2 · §5). Read when a bundle is activated: a bundle
  /// activated while it is null keeps its `kb` on the device for that
  /// activation.
  final ValueListenable<mk.KbAccountRecords?>? account;

  /// One account-backed store per account binding, so every activation made
  /// while the same account syncs shares its per-app lock and pending writes.
  mk.KbAccountRecords? _accountRecords;
  mk.KbRecordStore? _accountStore;

  /// The record store a bundle activated now writes through.
  mk.KbRecordStore get activeRecords {
    final bound = account?.value;
    if (bound == null) return records;
    if (!identical(bound, _accountRecords)) {
      _accountRecords = bound;
      _accountStore = mk.AccountKbRecordStore(account: bound, kv: _kv);
    }
    return _accountStore!;
  }

  /// Knowledge query behind `host.kb.query`. Null → the query verb answers
  /// `KB_QUERY_UNAVAILABLE`; the storage verbs still work.
  final mk.KnowledgeQueryEngine? engine;

  /// The former per-bundle storage (`<configRoot>/domains`), read once per
  /// app by [importLegacyOnce]. Null → nothing to import.
  // ignore: deprecated_member_use
  final mk.DomainStorage? legacy;

  final String? Function(mb.McpBundle bundle)? _appIdOf;

  /// `listing:<listingId>` when [appIdOf] knows the listing, else
  /// `bundle:<manifest.id>`.
  String appIdFor(mb.McpBundle bundle) =>
      _appIdOf?.call(bundle) ?? 'bundle:${bundle.manifest.id}';

  /// A `kb` view of [bundle]. Hold one per activation: the store remembers
  /// the version it last saw per key, which is what makes a write safe.
  mk.BundleKbStore storeFor(mb.McpBundle bundle) {
    final active = activeRecords;
    final store = mk.BundleKbStore(
      appId: appIdFor(bundle),
      records: active,
      engine: engine,
    );
    if (identical(active, records)) _onDevice[store] = true;
    return store;
  }

  /// Stores [storeFor] opened on the device records.
  final Expando<bool> _onDevice = Expando<bool>('kb store on device');

  /// Key of the marker that records the legacy import of [appId] ran.
  static String importMarkerKey(String appId) =>
      'studio/kb_import/${Uri.encodeComponent(appId)}';

  /// Moves [bundle]'s former `DomainStorage` namespace (its manifest id) into
  /// [store] the first time this app is seen, and never again. Returns the
  /// report when an import ran, null when it had already run, there is no
  /// legacy storage, or [store] is on the account.
  ///
  /// The old files are this device's, so they are imported into the device
  /// records only. An account write the account refused would otherwise be
  /// marked as imported and never tried again.
  Future<mk.KbImportReport?> importLegacyOnce(
    mb.McpBundle bundle,
    mk.BundleKbStore store,
  ) async {
    final source = legacy;
    if (source == null) return null;
    if (_onDevice[store] != true) return null;
    final marker = importMarkerKey(store.appId);
    if (await _kv.exists(marker)) return null;
    final report = await mk.importDomainStorageNamespace(
      source: source,
      namespace: bundle.manifest.id,
      target: store,
    );
    await _kv.set(marker, <String, dynamic>{
      'namespace': bundle.manifest.id,
      'at': DateTime.now().toUtc().toIso8601String(),
      'imported': report.imported,
      'alreadyPresent': report.alreadyPresent,
      'skipped': report.skipped,
    });
    return report;
  }
}
