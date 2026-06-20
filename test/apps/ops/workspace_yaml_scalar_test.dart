/// Unit tests for `WorkspaceRegistry._toYamlString` / `_scalar` logic.
///
/// These private helpers are tested through observable behaviour:
/// create a workspace with special-char title/tags, read the config.yaml back,
/// and parse it to confirm round-trip fidelity. Boot-independent: uses a real
/// temp dir + the public WorkspaceRegistry API.
///
/// Scenarios:
///   ys1  title containing ':' is written / read back correctly (quoted scalar)
///   ys2  title containing '#' is written / read back correctly (quoted scalar)
///   ys3  plain title (no special chars) round-trips without quoting noise
///   ys4  tags map with colon in value round-trips correctly
///   ys5  empty tags writes as '{}' or empty map — reads back as empty
///   ys6  locale and timezone round-trip through YAML scalar
///   ys7  sharedWith list with entries round-trips correctly
library;

import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';

Future<(WorkspaceRegistry, Directory)> _makeReg() async {
  final tmp = await Directory.systemTemp.createTemp('ws_yaml_scalar_test_');
  final kv = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv'));
  final reg = WorkspaceRegistry(kv: kv, rootDir: tmp.path);
  return (reg, tmp);
}

void main() {
  late WorkspaceRegistry reg;
  late Directory tmp;

  setUp(() async {
    (reg, tmp) = await _makeReg();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ys1
  test('ys1 title with colon round-trips correctly', () async {
    final ws = await reg.create(
      type: WorkspaceType.project,
      slug: 'colon',
      title: 'Ops: Production',
    );
    // Force a fresh load from disk via a new registry instance.
    final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
    final reg2 = WorkspaceRegistry(kv: kv2, rootDir: tmp.path);
    final loaded = await reg2.get(ws.id);
    expect(loaded, isNotNull);
    expect(loaded!.title, 'Ops: Production');
  });

  // ys2
  test('ys2 title with hash round-trips correctly', () async {
    final ws = await reg.create(
      type: WorkspaceType.project,
      slug: 'hash',
      title: 'Sprint #3',
    );
    final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
    final reg2 = WorkspaceRegistry(kv: kv2, rootDir: tmp.path);
    final loaded = await reg2.get(ws.id);
    expect(loaded, isNotNull);
    expect(loaded!.title, 'Sprint #3');
  });

  // ys3
  test('ys3 plain title round-trips without quoting noise', () async {
    final ws = await reg.create(
      type: WorkspaceType.org,
      slug: 'plain',
      title: 'Acme Corp',
    );
    final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
    final reg2 = WorkspaceRegistry(kv: kv2, rootDir: tmp.path);
    final loaded = await reg2.get(ws.id);
    expect(loaded!.title, 'Acme Corp');
  });

  // ys4
  test('ys4 tags map with colon in value round-trips correctly', () async {
    final ws = await reg.create(
      type: WorkspaceType.project,
      slug: 'tagged',
      title: 'Tagged',
      tags: const {'env': 'prod:v2', 'region': 'us-east-1'},
    );
    final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
    final reg2 = WorkspaceRegistry(kv: kv2, rootDir: tmp.path);
    final loaded = await reg2.get(ws.id);
    expect(loaded!.tags['env'], 'prod:v2');
    expect(loaded.tags['region'], 'us-east-1');
  });

  // ys5
  test('ys5 empty tags reads back as empty map', () async {
    final ws = await reg.create(
      type: WorkspaceType.personal,
      slug: 'notags',
      title: 'No Tags',
    );
    final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
    final reg2 = WorkspaceRegistry(kv: kv2, rootDir: tmp.path);
    final loaded = await reg2.get(ws.id);
    expect(loaded!.tags, isEmpty);
  });

  // ys6
  test('ys6 locale and timezone round-trip', () async {
    final ws = await reg.create(
      type: WorkspaceType.project,
      slug: 'locale',
      title: 'Locale',
      locale: 'ja',
      timezone: 'Asia/Tokyo',
    );
    final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
    final reg2 = WorkspaceRegistry(kv: kv2, rootDir: tmp.path);
    final loaded = await reg2.get(ws.id);
    expect(loaded!.locale, 'ja');
    expect(loaded.timezone, 'Asia/Tokyo');
  });

  // ys7
  test('ys7 sharedWith list round-trips correctly', () async {
    await reg.create(type: WorkspaceType.org, slug: 'src', title: 'Source');
    await reg.create(
      type: WorkspaceType.org,
      slug: 'dst',
      title: 'Destination',
    );
    await reg.share('org/src', 'org/dst');
    final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
    final reg2 = WorkspaceRegistry(kv: kv2, rootDir: tmp.path);
    final loaded = await reg2.get('org/src');
    expect(loaded!.sharedWith, contains('org/dst'));
  });
}
