/// One saved fact is one query result. `saveFact` writes the fact to the
/// graph and mirrors it to KV; `query` merged both halves, so every saved
/// fact came back twice (`fact/policy/refund` and `policy/refund`).
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
  test('a saved fact is returned once', () async {
    final tmp = Directory.systemTemp.createTempSync('fact_dedupe_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    await init.registries.workspace.create(
      type: WorkspaceType.project,
      slug: 'kn',
      title: 'Kn',
    );
    await init.registries.workspace.setActive('project/kn');
    final k = init.registries.knowledge;
    await k.saveFact(category: 'policy', key: 'refund', value: '14 days');

    final hits = await k.query('refund', limit: 20);
    final domain = hits.where((f) => !f.type.startsWith('agent')).toList();
    expect(domain.map((f) => f.id), ['fact/policy/refund']);
    // The KV mirror itself is still there for KV readers.
    expect((await k.listKvFacts(filter: 'refund')).length, 1);
  });
}
