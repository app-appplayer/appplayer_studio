/// The studio's `host.kb` wiring: one record store on the kernel key/value
/// store, app identity decided by the host, and the former per-bundle domain
/// storage imported once per app — never overwriting, never deleting the
/// source, and never bringing back a key the bundle deleted.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/install/studio_kb.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
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
  late Directory tmp;
  late mk.KvStoragePortAdapter kv;
  // ignore: deprecated_member_use
  late mk.JsonFileDomainStorage legacy;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('studio_kb_');
    kv = mk.KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv'));
    // ignore: deprecated_member_use
    legacy = mk.JsonFileDomainStorage(rootDir: p.join(tmp.path, 'domains'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('app identity: bundle:<manifest.id> unless the host names one', () {
    final bundle = _bundle(tmp, 'com.example.desk');
    expect(StudioKbWiring(kv: kv).appIdFor(bundle), 'bundle:com.example.desk');
    final listed = StudioKbWiring(
      kv: kv,
      appIdOf: (b) => b.manifest.id == 'com.example.desk' ? 'listing:L7' : null,
    );
    expect(listed.appIdFor(bundle), 'listing:L7');
  });

  test('the former domain storage is imported and readable', () async {
    final bundle = _bundle(tmp, 'com.example.desk');
    await legacy.put('com.example.desk', 'today', {'s1': 'present'});
    await legacy.put('com.example.desk', 'paySeq', 3);
    final wiring = StudioKbWiring(kv: kv, legacy: legacy);
    final store = wiring.storeFor(bundle);

    final report = await wiring.importLegacyOnce(bundle, store);

    expect(report, isNotNull);
    expect(report!.imported.toSet(), {'today', 'paySeq'});
    expect(await store.get('today'), {'s1': 'present'});
    expect(await store.get('paySeq'), 3);
    // The source stays where it was.
    expect(await legacy.get('com.example.desk', 'paySeq'), 3);
  });

  test('the import never overwrites what kb already holds', () async {
    final bundle = _bundle(tmp, 'com.example.desk');
    await legacy.put('com.example.desk', 'paySeq', 3);
    final wiring = StudioKbWiring(kv: kv, legacy: legacy);
    final store = wiring.storeFor(bundle);
    await store.put('paySeq', 9);

    final report = await wiring.importLegacyOnce(bundle, store);

    expect(report!.alreadyPresent, contains('paySeq'));
    expect(await store.get('paySeq'), 9);
  });

  test('it runs once: a deleted key does not come back', () async {
    final bundle = _bundle(tmp, 'com.example.desk');
    await legacy.put('com.example.desk', 'draft', 'old');
    final wiring = StudioKbWiring(kv: kv, legacy: legacy);
    final store = wiring.storeFor(bundle);
    await wiring.importLegacyOnce(bundle, store);
    expect(await store.delete('draft'), {'removed': true});

    // A later activation — a fresh wiring and store over the same kv.
    final again = StudioKbWiring(kv: kv, legacy: legacy);
    final second = again.storeFor(bundle);
    expect(await again.importLegacyOnce(bundle, second), isNull);
    expect(await second.get('draft'), isNull);
  });

  test('state survives a restart (a new kv adapter on the same root)', () async {
    final bundle = _bundle(tmp, 'com.example.desk');
    final wiring = StudioKbWiring(kv: kv);
    await wiring.storeFor(bundle).put('a', {'n': 1});

    final restarted = StudioKbWiring(
      kv: mk.KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv')),
    );
    expect(await restarted.storeFor(bundle).get('a'), {'n': 1});
  });
}
