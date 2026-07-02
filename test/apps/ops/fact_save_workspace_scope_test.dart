/// Fact save/query workspace-scope override — integration regression over a
/// real `KnowledgeInit.boot`.
///
/// Reproduces konpi test2 #5: `knowledge_fact_save` attributed a fact to the
/// caller's active / execution-pinned workspace, so an HR-pinned agent
/// recording an onboarding fact ABOUT an `org/media` member wrote it under
/// `org/hr`. `saveFact(workspaceId:)` now targets a specific department, and
/// `query(workspaceId:)` round-trips it (both the FactGraph and the KV half).
///
///   t1  a fact saved with an explicit `workspaceId` lands in THAT ws — a
///       query scoped there finds it, a query scoped to the active ws does not.
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
  setUp(() => tmp = Directory.systemTemp.createTempSync('fact_ws_scope_'));
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  test('saveFact(workspaceId:) targets a department; query round-trips + isolates',
      () async {
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    final ws = init.registries.workspace;
    await ws.create(type: WorkspaceType.org, slug: 'hr', title: 'People');
    await ws.create(type: WorkspaceType.org, slug: 'media', title: 'Media');

    // Pin the caller to org/hr, but attribute the fact to org/media (the dept
    // it is ABOUT) via the explicit override — the reported scenario.
    await ws.setActive('org/hr');
    await init.registries.knowledge.saveFact(
      category: 'onboarding',
      key: 'milo_start',
      value: 'Milo joined the media desk',
      workspaceId: 'org/media',
    );

    // Scoped to org/media → the fact is found (graph + KV both honor the ws).
    final inMedia = await init.registries.knowledge.query(
      'Milo',
      workspaceId: 'org/media',
    );
    expect(
      inMedia.any((f) => f.content.toString().contains('media desk')),
      isTrue,
      reason: 'fact must be readable in its target workspace',
    );

    // Scoped to the caller's active ws (org/hr) → NOT leaked there.
    final inHr = await init.registries.knowledge.query(
      'Milo',
      workspaceId: 'org/hr',
    );
    expect(
      inHr.any((f) => f.content.toString().contains('media desk')),
      isFalse,
      reason: 'fact must NOT land in the caller\'s pinned workspace',
    );
  });
}
