/// "Today's flow" (B4) poll — hour bucketing over a real KnowledgeInit:
/// today's facts land in their local-hour lane, yesterday's don't, and a
/// null workspace yields the empty snapshot.
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';
import 'package:appplayer_studio/src/apps/ops/ui/home/today_flow_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as bundle;

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
  test('buckets today by local hour; ignores yesterday; null ws = empty',
      () async {
    final tmp = Directory.systemTemp.createTempSync('today_flow_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    await init.registries.workspace
        .create(type: WorkspaceType.org, slug: 'dev', title: 'Dev');

    final now = DateTime.now();
    Future<void> fact(String type, DateTime at, String id) =>
        init.registries.knowledge.knowledgeSystem.facts.writeFacts([
          bundle.FactRecord(
            id: id,
            workspaceId: 'org/dev',
            type: type,
            entityId: 'a1',
            content: const {'agentId': 'a1', 'targetAgentId': 'a1',
                'fromAgentId': 'lead'},
            confidence: 1.0,
            createdAt: at,
          ),
        ]);

    await fact('agent.invoked', now, 'i/1');
    await fact('agent.invoked', now, 'i/2');
    await fact('agent.routed', now, 'r/1');
    await fact('agent.invoked', now.subtract(const Duration(days: 1)), 'i/3');

    final data = await pollTodayFlow(init, 'org/dev');
    expect(data.invoked[now.hour], 2);
    expect(data.routed[now.hour], 1);
    // Yesterday's invocation is not in any of today's buckets.
    expect(data.invoked.values.fold<int>(0, (a, b) => a + b), 2);
    expect(data.runsStarted, isEmpty);

    expect((await pollTodayFlow(init, null)).isEmpty, isTrue);
  });
}
