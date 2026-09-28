/// `host.kb` on the account (platform spec 20 §2 · §5): while this device
/// syncs, a bundle activated now keeps its records in the account's
/// `app/<appId>` scope; otherwise on the device. The choice is made when the
/// bundle is activated, and this device's old domain files only ever go into
/// the device records.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/account/account_storage.dart';
import 'package:appplayer_studio/src/base/account/in_memory_account_storage.dart';
import 'package:appplayer_studio/src/base/account/kb_account_records.dart';
import 'package:appplayer_studio/src/base/install/studio_kb.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:path/path.dart' as p;

mb.McpBundle _bundle(Directory root, String id) {
  final dir = Directory(p.join(root.path, '$id.mbd'))..createSync();
  File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
    jsonEncode({
      'manifest': {'id': id, 'name': id, 'version': '1'},
    }),
  );
  return mb.McpBundle.fromJson(
    jsonDecode(File(p.join(dir.path, 'manifest.json')).readAsStringSync())
        as Map<String, dynamic>,
  );
}

void main() {
  const appId = 'bundle:com.example.desk';
  late Directory tmp;
  late mk.KvStoragePortAdapter kv;
  late InMemoryAccountStorage account;
  late ValueNotifier<mk.KbAccountRecords?> binding;
  late StudioKbWiring wiring;
  late mb.McpBundle bundle;

  Future<List<String>> accountKeys() async =>
      (await account.list(StorageScope.app(appId))).map((e) => e.key).toList();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('studio_kb_account_');
    kv = mk.KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv'));
    account = InMemoryAccountStorage();
    binding = ValueNotifier<mk.KbAccountRecords?>(null);
    wiring = StudioKbWiring(kv: kv, account: binding);
    bundle = _bundle(tmp, 'com.example.desk');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('not syncing: records stay on the device', () async {
    final store = wiring.storeFor(bundle);
    expect(await store.put('visits', 1), {'ok': true});
    expect(await accountKeys(), isEmpty);
    expect(await store.get('visits'), 1);
  });

  test('syncing: records land in app/<appId>, one per key', () async {
    binding.value = AccountStorageKbRecords(account);
    final store = wiring.storeFor(bundle);
    expect(await store.put('visits', 1), {'ok': true});
    expect(await accountKeys(), <String>['kb/visits']);

    // Another activation — another device reading the same account.
    final other = StudioKbWiring(
      kv: mk.KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2')),
      account: ValueNotifier<mk.KbAccountRecords?>(
        AccountStorageKbRecords(account),
      ),
    );
    expect(await other.storeFor(bundle).get('visits'), 1);
  });

  test('the choice is made at activation: a store opened before joining '
      'stays on the device', () async {
    final before = wiring.storeFor(bundle);
    binding.value = AccountStorageKbRecords(account);
    await before.put('visits', 1);
    expect(await accountKeys(), isEmpty);

    final after = wiring.storeFor(bundle);
    await after.put('visits', 2);
    expect(await accountKeys(), <String>['kb/visits']);
  });

  test('activations under one binding share one account store; a new '
      'binding gets its own', () {
    final records = AccountStorageKbRecords(account);
    binding.value = records;
    final first = wiring.activeRecords;
    expect(identical(wiring.activeRecords, first), isTrue);

    binding.value = AccountStorageKbRecords(account);
    expect(identical(wiring.activeRecords, first), isFalse);

    binding.value = null;
    expect(identical(wiring.activeRecords, wiring.records), isTrue);
  });

  test('old domain files are not imported into the account, and the import '
      'is still pending for the device', () async {
    // ignore: deprecated_member_use
    final legacy = mk.JsonFileDomainStorage(
      rootDir: p.join(tmp.path, 'domains'),
    );
    await legacy.put('com.example.desk', 'paySeq', 3);
    final withLegacy = StudioKbWiring(kv: kv, legacy: legacy, account: binding);

    binding.value = AccountStorageKbRecords(account);
    final onAccount = withLegacy.storeFor(bundle);
    expect(await withLegacy.importLegacyOnce(bundle, onAccount), isNull);
    expect(await accountKeys(), isEmpty);
    expect(await kv.exists(StudioKbWiring.importMarkerKey(appId)), isFalse);

    binding.value = null;
    final onDevice = withLegacy.storeFor(bundle);
    final report = await withLegacy.importLegacyOnce(bundle, onDevice);
    expect(report, isNotNull);
    expect(await onDevice.get('paySeq'), 3);
  });
}
