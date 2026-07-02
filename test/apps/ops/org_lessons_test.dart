/// Org memory (RFC4) — PURPOSE proof: a lesson recorded at the org level
/// persists as a workspace-scoped fact (so it outlives member turnover) and is
/// retrievable. Reuses the per-project FactGraph (`saveFact` /
/// `graphFactsForWorkspace` / `listKvFacts`) — no new store, no kernel.
///
///   l1  a recorded `org_lesson` is retrievable via listKvFacts (with metadata)
///   l2  it is workspace-scoped in the graph (graphFactsForWorkspace by category)
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
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
  setUp(() => tmp = Directory.systemTemp.createTempSync('org_lessons_'));
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  test('l1/l2 an org lesson persists workspace-scoped and is retrievable',
      () async {
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    final kn = init.registries.knowledge;

    await kn.saveFact(
      category: 'org_lesson',
      key: 'lesson_1',
      value: 'evidence beats opinion',
      metadata: const {'situation': 'op-ed drift', 'outcome': 'rejected'},
    );

    // l1 — retrievable via KV listing (carries the metadata shape).
    final kv = await kn.listKvFacts();
    final lessons = kv.where((f) => f.category == 'org_lesson').toList();
    expect(lessons, hasLength(1));
    expect(lessons.first.value, 'evidence beats opinion');
    expect(lessons.first.metadata['situation'], 'op-ed drift');

    // l2 — workspace-scoped in the graph (category filter).
    final graph = await kn.graphFactsForWorkspace(
      init.registries.workspace.activeId ?? '_system',
      category: 'org_lesson',
      limit: 500,
    );
    expect(graph, isNotEmpty);
  });
}
