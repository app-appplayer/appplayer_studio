/// Active-workspace defaulting + switch durability — integration regression
/// over a real `KnowledgeInit.boot`.
///
/// Addresses the reported UX: after deleting the active workspace, Home landed
/// on the empty reserved `_system` slot with nothing selected. Three behaviors
/// now keep a sensible lens selected and durable:
///   ad1  `switchWorkspace` persists the per-project active pointer
///        (`<root>/.makemind-ops-active`), so a UI switch survives a reboot
///        (previously only the MCP handler wrote it — UI switches were
///        in-memory only).
///   ad2  boot defaults away from the reserved `_system` slot to the first real
///        workspace when one exists, so Home lands on content, not the empty
///        admin slot.
///   ad3  deleting the ACTIVE workspace reselects the first remaining one (the
///        two-step the `workspace_delete` handler runs) and persists it.
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';
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

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ws_active_'));
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  test('ad1 — switchWorkspace persists the per-project active pointer', () async {
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    await init.registries.workspace
        .create(type: WorkspaceType.org, slug: 'alpha', title: 'Alpha');
    await init.switchWorkspace('org/alpha');

    final ptr = File('${tmp.path}/.makemind-ops-active');
    expect(ptr.existsSync(), isTrue, reason: 'pointer file must be written');
    expect(ptr.readAsStringSync().trim(), 'org/alpha');
    expect(init.registries.workspace.activeId, 'org/alpha');
  });

  test('ad2 — boot defaults _system → first real workspace', () async {
    // First boot: author two departments, then let it go.
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    await init.registries.workspace
        .create(type: WorkspaceType.org, slug: 'beta', title: 'Beta');
    await init.registries.workspace
        .create(type: WorkspaceType.org, slug: 'alpha', title: 'Alpha');

    // Reboot with the config's active = `_system` (the empty admin slot). The
    // boot must default to the first real workspace (id-sorted → org/alpha).
    final init2 = await KnowledgeInit.boot(_bound(tmp.path));
    expect(
      init2.registries.workspace.activeId,
      'org/alpha',
      reason: 'boot must land on a real workspace, not the empty _system slot',
    );
  });

  test('ad3 — deleting the active workspace reselects the first remaining',
      () async {
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    final ws = init.registries.workspace;
    await ws.create(type: WorkspaceType.org, slug: 'alpha', title: 'Alpha');
    await ws.create(type: WorkspaceType.org, slug: 'beta', title: 'Beta');
    await init.switchWorkspace('org/alpha');
    expect(ws.activeId, 'org/alpha');

    // The two-step the `workspace_delete` handler runs when the deleted id is
    // the active lens: delete, then reselect the first remaining + persist.
    const deleted = 'org/alpha';
    final wasActive = ws.activeId == deleted;
    await ws.delete(deleted);
    init.registries.member.evictWorkspace(deleted);
    if (wasActive) {
      final remaining = await ws.list();
      await init.switchWorkspace(
        remaining.isNotEmpty ? remaining.first.id : WorkspaceRegistry.systemWorkspaceId,
      );
    }

    expect(ws.activeId, 'org/beta', reason: 'active must fall to the survivor');
    expect(
      File('${tmp.path}/.makemind-ops-active').readAsStringSync().trim(),
      'org/beta',
      reason: 'the reselected active must be persisted',
    );
  });
}
