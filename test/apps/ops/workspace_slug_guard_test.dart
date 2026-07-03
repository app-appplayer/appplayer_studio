/// A slash in a workspace slug composes an id whose metadata dir nests one
/// level deeper than the reload scan reads: the workspace is created and
/// works in-session, then silently VANISHES from the registry on the next
/// boot (round-trip hole, live-caught 2026-07-03 while building a 12-unit
/// test org with `org/<name>` slugs). The registry now rejects it up front.
///
///   sg1  create with a slash slug throws (nothing persisted)
///   sg2  a flat slug round-trips a registry reload
library;

import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ws_slug_'));
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  WorkspaceRegistry registryOn(String root) => WorkspaceRegistry(
    rootDir: root,
    kv: KvStoragePortAdapter(rootDir: p.join(root, 'kv')),
  );

  test('sg1: slash slug is rejected up front — no dirs, no registry entry',
      () async {
    final reg = registryOn(tmp.path);
    await expectLater(
      reg.create(type: WorkspaceType.org, slug: 'org/hq', title: 'HQ'),
      throwsArgumentError,
    );
    expect(Directory('${tmp.path}/org/org/hq').existsSync(), isFalse);
    expect(await reg.list(), isEmpty);
  });

  test('sg2: flat slug survives a registry reload (the round-trip the '
      'slash slug broke)', () async {
    final reg = registryOn(tmp.path);
    await reg.create(type: WorkspaceType.org, slug: 'hq', title: 'HQ');
    final reloaded = registryOn(tmp.path);
    expect((await reloaded.list()).map((w) => w.id), contains('org/hq'));
  });
}
