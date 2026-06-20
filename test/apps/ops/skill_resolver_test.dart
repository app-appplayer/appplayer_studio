/// SkillResolver — unit tests for all unit-testable paths.
///
/// Paths that touch live flowbrain / OpsBuiltInApp are skipped.
/// The catalog fallback, invalidation, and visibleIds combining are
/// fully testable without a live boot.
///
/// Scenarios:
///   sv1  resolve — falls back to catalog when workspace files absent
///   sv2  resolve — returns null when not in catalog and no ws files
///   sv3  resolve — caches result (file created after first resolve not seen)
///   sv4  invalidate(skillId) — clears ws cache entry so next resolve re-reads
///   sv5  invalidate() — clears all cache entries
///   sv6  visibleIds — returns catalog ids when no workspace dirs exist
///   sv7  visibleIds — adds workspace file ids on top of catalog ids
///   sv8  visibleIds — adds agent-specific ids on top of workspace ids
///   sv9  resolve with workspaceId, no actorId — reads workspace layer only
///   sv10 resolve with both ids, agent file present — returns agent overlay
///   sv11 resolve with both ids, agent file absent — falls through to ws layer
///   sv12 resolve — corrupted YAML in workspace file returns null (no crash)
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/apps/ops/skills/skill_definition.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_registry.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_resolver.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

SkillDefinition _def(String id) => SkillDefinition.fromYaml({
  'id': id,
  'version': 1,
  'description': 'catalog $id',
  'actionBody': {'kind': 'noop'},
});

String _wsRoot(String root, String wsId) =>
    '$root/${wsId.replaceAll('/', '_')}.mbd';

/// Write a minimal valid skill YAML at [path].
Future<void> _writeSkillYaml(String path, String id) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString('''
id: $id
version: 1
description: "from file"
actionBody:
  kind: noop
''');
}

void main() {
  late Directory tmp;
  late AppSkillRegistry catalog;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('skill_resolver_test_');
    catalog = AppSkillRegistry();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  SkillResolver _makeResolver() =>
      SkillResolver(catalog: catalog, workspacesRoot: tmp.path);

  // sv1
  test(
    'sv1 resolve falls back to catalog when workspace files absent',
    () async {
      final def = _def('summarize');
      catalog.register(def);
      final resolver = _makeResolver();
      final result = await resolver.resolve(
        'summarize',
        workspaceId: 'org/test',
      );
      expect(result, same(def));
    },
  );

  // sv2
  test(
    'sv2 resolve returns null when not in catalog and no ws files',
    () async {
      final resolver = _makeResolver();
      final result = await resolver.resolve('unknown_skill');
      expect(result, isNull);
    },
  );

  // sv3
  test(
    'sv3 resolve caches successful ws result (re-resolve same file returns same instance)',
    () async {
      catalog.register(_def('base'));
      final resolver = _makeResolver();
      final wsId = 'org/cache';
      final wsRoot = _wsRoot(tmp.path, wsId);
      final skillPath = '$wsRoot/skills/base.yaml';

      // Write the file before first resolve.
      await _writeSkillYaml(skillPath, 'base');

      // First resolve — file exists, should be loaded and cached.
      final first = await resolver.resolve('base', workspaceId: wsId);
      expect(first, isNotNull);
      expect(first!.description, 'from file');

      // Second resolve — cache should return the same instance.
      final second = await resolver.resolve('base', workspaceId: wsId);
      expect(second, same(first));
    },
  );

  // sv4
  test('sv4 invalidate(skillId) clears ws cache for that skill', () async {
    catalog.register(_def('skill_a'));
    final resolver = _makeResolver();
    const wsId = 'org/inval';
    final wsRoot = _wsRoot(tmp.path, wsId);
    final skillPath = '$wsRoot/skills/skill_a.yaml';

    // First resolve with no file — caches null for ws layer.
    await resolver.resolve('skill_a', workspaceId: wsId);

    // Write the ws file.
    await _writeSkillYaml(skillPath, 'skill_a');

    // Invalidate the ws cache entry.
    resolver.invalidate(workspaceId: wsId, skillId: 'skill_a');

    // Now resolve should find the file.
    final result = await resolver.resolve('skill_a', workspaceId: wsId);
    expect(result, isNotNull);
    expect(result!.id, 'skill_a');
    expect(result.description, 'from file');
  });

  // sv5
  test('sv5 invalidate() with no args clears all caches', () async {
    catalog.register(_def('skill_b'));
    final resolver = _makeResolver();
    const wsId = 'org/all';
    final wsRoot = _wsRoot(tmp.path, wsId);
    final skillPath = '$wsRoot/skills/skill_b.yaml';

    // Cache a null entry for the ws layer.
    await resolver.resolve('skill_b', workspaceId: wsId);

    // Write the ws file.
    await _writeSkillYaml(skillPath, 'skill_b');

    // Clear all caches.
    resolver.invalidate();

    // Next resolve should hit disk.
    final result = await resolver.resolve('skill_b', workspaceId: wsId);
    expect(result, isNotNull);
    expect(result!.description, 'from file');
  });

  // sv6
  test(
    'sv6 visibleIds returns catalog ids when no workspace dirs exist',
    () async {
      catalog.register(_def('c1'));
      catalog.register(_def('c2'));
      final resolver = _makeResolver();
      final ids = await resolver.visibleIds();
      expect(ids, containsAll(['c1', 'c2']));
    },
  );

  // sv7
  test(
    'sv7 visibleIds adds workspace file ids on top of catalog ids',
    () async {
      catalog.register(_def('catalog_skill'));
      final resolver = _makeResolver();
      const wsId = 'org/visible';
      final wsRoot = _wsRoot(tmp.path, wsId);
      await _writeSkillYaml('$wsRoot/skills/ws_skill.yaml', 'ws_skill');

      final ids = await resolver.visibleIds(workspaceId: wsId);
      expect(ids, containsAll(['catalog_skill', 'ws_skill']));
    },
  );

  // sv8
  test(
    'sv8 visibleIds adds agent-specific ids on top of ws+catalog ids',
    () async {
      catalog.register(_def('base_skill'));
      final resolver = _makeResolver();
      const wsId = 'org/agents';
      const agentId = 'agent_007';
      final wsRoot = _wsRoot(tmp.path, wsId);
      await _writeSkillYaml('$wsRoot/skills/ws_skill.yaml', 'ws_skill');
      await _writeSkillYaml(
        '$wsRoot/members/$agentId/skills/agent_skill.yaml',
        'agent_skill',
      );

      final ids = await resolver.visibleIds(
        workspaceId: wsId,
        actorId: agentId,
      );
      expect(ids, containsAll(['base_skill', 'ws_skill', 'agent_skill']));
    },
  );

  // sv9
  test('sv9 resolve with workspaceId only reads workspace layer', () async {
    final resolver = _makeResolver();
    const wsId = 'org/layer';
    final wsRoot = _wsRoot(tmp.path, wsId);
    await _writeSkillYaml('$wsRoot/skills/my_skill.yaml', 'my_skill');

    final result = await resolver.resolve('my_skill', workspaceId: wsId);
    expect(result, isNotNull);
    expect(result!.id, 'my_skill');
    expect(result.description, 'from file');
  });

  // sv10
  test(
    'sv10 resolve with actorId returns agent overlay when file exists',
    () async {
      catalog.register(_def('shared'));
      final resolver = _makeResolver();
      const wsId = 'org/over';
      const agentId = 'agent_x';
      final wsRoot = _wsRoot(tmp.path, wsId);
      // Write both ws and agent versions.
      await _writeSkillYaml('$wsRoot/skills/shared.yaml', 'shared');
      final agentFile = '$wsRoot/members/$agentId/skills/shared.yaml';
      final agentSkillFile = File(agentFile);
      await agentSkillFile.parent.create(recursive: true);
      await agentSkillFile.writeAsString('''
id: shared
version: 99
description: "agent overlay"
actionBody:
  kind: noop
''');

      final result = await resolver.resolve(
        'shared',
        workspaceId: wsId,
        actorId: agentId,
      );
      expect(result, isNotNull);
      expect(result!.version, 99);
      expect(result.description, 'agent overlay');
    },
  );

  // sv11
  test(
    'sv11 resolve agent layer absent falls through to workspace layer',
    () async {
      final resolver = _makeResolver();
      const wsId = 'org/fallthru';
      const agentId = 'no_agent_file';
      final wsRoot = _wsRoot(tmp.path, wsId);
      await _writeSkillYaml('$wsRoot/skills/fallthru.yaml', 'fallthru');

      // No agent file — should fall through to workspace layer.
      final result = await resolver.resolve(
        'fallthru',
        workspaceId: wsId,
        actorId: agentId,
      );
      expect(result, isNotNull);
      expect(result!.id, 'fallthru');
      expect(result.description, 'from file');
    },
  );

  // sv12
  test('sv12 corrupted YAML in workspace file returns null', () async {
    final resolver = _makeResolver();
    const wsId = 'org/corrupt';
    final wsRoot = _wsRoot(tmp.path, wsId);
    final badFile = File('$wsRoot/skills/broken.yaml');
    await badFile.parent.create(recursive: true);
    await badFile.writeAsString(': : invalid : yaml :::');

    // Should not throw; returns null gracefully.
    final result = await resolver.resolve('broken', workspaceId: wsId);
    expect(result, isNull);
  });
}
