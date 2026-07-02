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
///   sv13 visibleIds/resolve — workspace-origin skill hidden from sibling ws
///   sv14 visibleIds/resolve — template (no origin) visible in every ws
///   sv15 ancestor chain — child inherits parent skill, not vice versa
///   sv16 ancestor chain — parent's on-disk skill resolved from child
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

  // --- workspace-scope isolation (origin filter) ---------------------------

  // sv13 — a workspace-authored catalog skill (registered with workspaceId)
  // must NOT be visible to a sibling workspace.
  test('sv13 workspace-origin skill hidden from sibling workspace', () async {
    catalog.register(_def('recruit'), workspaceId: 'org/devteam');
    final resolver = _makeResolver();

    // Visible in its own workspace.
    final own = await resolver.visibleIds(workspaceId: 'org/devteam');
    expect(own, contains('recruit'));
    expect(
      await resolver.resolve('recruit', workspaceId: 'org/devteam'),
      isNotNull,
    );

    // Hidden in a sibling.
    final sibling = await resolver.visibleIds(workspaceId: 'org/devmag');
    expect(sibling, isNot(contains('recruit')));
    expect(
      await resolver.resolve('recruit', workspaceId: 'org/devmag'),
      isNull,
    );
  });

  // sv14 — a genuine template (registered without workspaceId) stays globally
  // visible, matching the pre-existing catalog semantics.
  test('sv14 template (no origin) visible in every workspace', () async {
    catalog.register(_def('summarize')); // no workspaceId = template
    final resolver = _makeResolver();
    for (final ws in ['org/a', 'org/b']) {
      expect(await resolver.visibleIds(workspaceId: ws), contains('summarize'));
      expect(await resolver.resolve('summarize', workspaceId: ws), isNotNull);
    }
  });

  // sv15 — a parent's workspace-origin skill is inherited by a child through
  // the ancestor chain, but a child's is NOT visible to the parent.
  test('sv15 ancestor chain — child inherits parent, not vice versa', () async {
    catalog.register(_def('org_policy'), workspaceId: 'org/root');
    catalog.register(_def('team_only'), workspaceId: 'org/child');
    final resolver = SkillResolver(
      catalog: catalog,
      workspacesRoot: tmp.path,
      ancestorsOf: (id) async => id == 'org/child' ? ['org/root'] : const [],
    );

    // Child sees both its own and the inherited parent skill.
    final child = await resolver.visibleIds(workspaceId: 'org/child');
    expect(child, containsAll(['org_policy', 'team_only']));
    expect(
      await resolver.resolve('org_policy', workspaceId: 'org/child'),
      isNotNull,
    );

    // Parent sees only its own — the child skill does not leak upward.
    final parent = await resolver.visibleIds(workspaceId: 'org/root');
    expect(parent, contains('org_policy'));
    expect(parent, isNot(contains('team_only')));
    expect(
      await resolver.resolve('team_only', workspaceId: 'org/root'),
      isNull,
    );
  });

  // sv16 — a child's ancestor `skills/<id>.yaml` on disk is resolved through
  // the chain (disk inheritance, independent of the catalog).
  test('sv16 ancestor disk skill resolved through chain', () async {
    final resolver = SkillResolver(
      catalog: catalog,
      workspacesRoot: tmp.path,
      ancestorsOf: (id) async => id == 'org/child' ? ['org/root'] : const [],
    );
    await _writeSkillYaml(
      '${_wsRoot(tmp.path, 'org/root')}/skills/inherited.yaml',
      'inherited',
    );

    final ids = await resolver.visibleIds(workspaceId: 'org/child');
    expect(ids, contains('inherited'));
    final def = await resolver.resolve('inherited', workspaceId: 'org/child');
    expect(def, isNotNull);
    expect(def!.description, 'from file');
  });
}
