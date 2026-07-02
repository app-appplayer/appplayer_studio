/// Skill workspace-scope isolation — integration regression over a real
/// [KnowledgeInit.boot], exercising the wired `SkillResolver.ancestorsOf =
/// WorkspaceRegistry.ancestorIds` seam (not a fake, unlike the unit tests).
///
/// Reproduces the reported leak: a `scope:"workspace"` skill was visible in
/// every workspace's `skill_list`, and a parent org saw its children's skills.
///
///   w1  a workspace-authored skill is visible in its own workspace and its
///       org descendants, but NOT in a sibling or in its parent.
///   w2  an in-scope catalog entry (origin-tagged, as WorkspaceLoader /
///       skill_save register it) is filtered by the resolver per active ws.
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/infra/ws_paths.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_definition.dart';
import 'package:flutter_test/flutter_test.dart';

OpsConfig _bound(String root) => OpsConfig(
  version: 'test',
  appName: 'test',
  activeWorkspace: '_system',
  workspacesRoot: root,
  llm: const LlmSettings.empty(),
  mcp: const McpSettings.defaults(),
  browser: const BrowserSettings.defaults(),
  storage: StorageSettings(localKvPath: '$root/.kv'),
  channel: const ChannelSettings.empty(),
  security: const SecuritySettings.defaults(),
);

Future<void> _writeSkill(String root, String wsId, String id) async {
  final file = File('${wsContentRoot(root, wsId)}/skills/$id.yaml');
  await file.parent.create(recursive: true);
  await file.writeAsString('id: $id\nversion: 1\n'
      'description: "$id"\nactionBody:\n  kind: noop\n');
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('skill_ws_scope_'));
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  // Build the makemind/devmag/devteam org tree from the bug report:
  // makemind (root) ← devmag, makemind ← devteam (siblings under one parent).
  Future<KnowledgeInit> _bootOrgTree() async {
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    final ws = init.registries.workspace;
    await ws.create(type: WorkspaceType.org, slug: 'makemind', title: 'MM');
    await ws.create(type: WorkspaceType.org, slug: 'devmag', title: 'Mag');
    await ws.create(type: WorkspaceType.org, slug: 'devteam', title: 'Team');
    await ws.setParent('org/devmag', 'org/makemind');
    await ws.setParent('org/devteam', 'org/makemind');
    return init;
  }

  // --- w1: disk skills isolate by workspace, inherit down the org chain ---
  test('w1 workspace skill isolated from sibling/parent, inherited by child',
      () async {
    final init = await _bootOrgTree();
    await _writeSkill(tmp.path, 'org/makemind', 'org_policy'); // parent
    await _writeSkill(tmp.path, 'org/devmag', 'write_article'); // editorial
    await _writeSkill(tmp.path, 'org/devteam', 'recruit'); // dev team

    final r = init.skillResolver;

    // Parent sees only its own — not either child's skill.
    final mm = await r.visibleIds(workspaceId: 'org/makemind');
    expect(mm, contains('org_policy'));
    expect(mm, isNot(contains('write_article')));
    expect(mm, isNot(contains('recruit')));

    // devmag: own + inherited parent, NOT the sibling devteam's.
    final dm = await r.visibleIds(workspaceId: 'org/devmag');
    expect(dm, containsAll(['write_article', 'org_policy']));
    expect(dm, isNot(contains('recruit')));

    // devteam: own + inherited parent, NOT the sibling devmag's.
    final dt = await r.visibleIds(workspaceId: 'org/devteam');
    expect(dt, containsAll(['recruit', 'org_policy']));
    expect(dt, isNot(contains('write_article')));

    // resolve() honours the same scope — a sibling skill does not resolve.
    expect(await r.resolve('write_article', workspaceId: 'org/devteam'),
        isNull);
    expect(await r.resolve('org_policy', workspaceId: 'org/devteam'),
        isNotNull); // inherited
  });

  // --- w2: origin-tagged catalog entry filtered per active workspace ---
  test('w2 catalog entry tagged with owning ws is hidden from a sibling',
      () async {
    final init = await _bootOrgTree();
    // Simulate WorkspaceLoader / skill_save registering a devmag-authored
    // skill into the shared registry with its owning workspace.
    init.skills.register(
      SkillDefinition.fromYaml({
        'id': 'leaked',
        'version': 1,
        'description': 'devmag skill',
        'actionBody': {'kind': 'noop'},
      }),
      workspaceId: 'org/devmag',
    );
    final r = init.skillResolver;

    expect(await r.visibleIds(workspaceId: 'org/devmag'), contains('leaked'));
    expect(
        await r.visibleIds(workspaceId: 'org/devteam'), isNot(contains('leaked')));
    expect(await r.visibleIds(workspaceId: 'org/makemind'),
        isNot(contains('leaked')));
    expect(await r.resolve('leaked', workspaceId: 'org/devteam'), isNull);
  });

  // --- w3: the exact `skill_list` path — visibleIds keyed on the ACTIVE
  // workspace (setActive), matching how the tool resolves `wsId`. ---
  test('w3 skill_list path (active workspace) reflects only in-scope skills',
      () async {
    final init = await _bootOrgTree();
    await _writeSkill(tmp.path, 'org/makemind', 'org_policy');
    await _writeSkill(tmp.path, 'org/devmag', 'write_article');
    await _writeSkill(tmp.path, 'org/devteam', 'recruit');
    final ws = init.registries.workspace;
    final r = init.skillResolver;

    // Mirror the tool: wsId = registries.workspace.activeId.
    Future<Set<String>> listActive() async =>
        r.visibleIds(workspaceId: ws.activeId);

    await ws.setActive('org/makemind');
    expect(await listActive(), equals({'org_policy'}));

    await ws.setActive('org/devmag');
    expect(await listActive(), equals({'write_article', 'org_policy'}));

    await ws.setActive('org/devteam');
    expect(await listActive(), equals({'recruit', 'org_policy'}));
  });
}
