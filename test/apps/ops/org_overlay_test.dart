/// Living-org-chart overlay — poll aggregation + node-id resolution.
///
///   t1  resolver joins bare member ids AND qualified agent ids to chart
///       node ids (same-unit first, global fallback), drops self/unknown
///       routes, and fades strength with age.
///   t2  pollOrgOverlay over a real KnowledgeInit: only fresh
///       `agent.invoked` facts count as "working", today's outputs count
///       since local midnight, and only in-window `agent.routed` facts
///       become route events.
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';
import 'package:appplayer_studio/src/apps/ops/ui/organization/org_chart_model.dart';
import 'package:appplayer_studio/src/apps/ops/ui/organization/org_overlay.dart';
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
  test('resolver: member/agent ids → node ids, fallback, fade, drops', () {
    final inputs = [
      OrgWsInput(
        id: 'org/dev',
        title: 'Dev',
        type: 'org',
        agents: const [
          OrgAgentInput(
            agentId: 'ops.manager.dev_ab12',
            memberId: 'dev-lead',
            displayName: 'Lead',
          ),
          OrgAgentInput(
            agentId: 'ops.worker.dev_cd34',
            memberId: 'dev1',
            displayName: 'Dev One',
          ),
        ],
      ),
      OrgWsInput(
        id: 'org/qa',
        title: 'QA',
        type: 'org',
        agents: const [
          OrgAgentInput(
            agentId: 'ops.worker.qa_ef56',
            memberId: 'qa1',
            displayName: 'QA One',
          ),
        ],
      ),
    ];
    final now = DateTime(2026, 7, 4, 12);
    final raw = OrgOverlayData(
      workingAgentIds: const {'ops.worker.dev_cd34', 'ghost-agent'},
      pendingByUnit: const {'org/dev': 2},
      outputTodayByUnit: const {'org/dev': 7},
      routes: [
        // bare member ids, same unit — fresh.
        OrgRouteEvent(
          fromId: 'dev-lead',
          toId: 'dev1',
          wsId: 'org/dev',
          at: now.subtract(const Duration(seconds: 9)),
        ),
        // cross-unit target — resolved through the global fallback.
        OrgRouteEvent(
          fromId: 'dev-lead',
          toId: 'ops.worker.qa_ef56',
          wsId: 'org/dev',
          at: now.subtract(const Duration(seconds: 81)),
        ),
        // self route — dropped.
        OrgRouteEvent(
          fromId: 'dev1',
          toId: 'dev1',
          wsId: 'org/dev',
          at: now,
        ),
        // unknown target — dropped.
        OrgRouteEvent(
          fromId: 'dev-lead',
          toId: 'nobody',
          wsId: 'org/dev',
          at: now,
        ),
      ],
    );

    final ov = resolveOrgOverlay(inputs, raw, now: now);

    expect(ov.activeNodeIds, {'ag:org/dev:ops.worker.dev_cd34'});
    expect(ov.pendingByUnit['org/dev'], 2);
    expect(ov.outputTodayByUnit['org/dev'], 7);
    expect(ov.routeEdges, hasLength(2));
    final fresh = ov.routeEdges[0];
    expect(fresh.fromNodeId, 'ag:org/dev:ops.manager.dev_ab12');
    expect(fresh.toNodeId, 'ag:org/dev:ops.worker.dev_cd34');
    final old = ov.routeEdges[1];
    expect(old.toNodeId, 'ag:org/qa:ops.worker.qa_ef56');
    expect(fresh.strength, greaterThan(old.strength));
  });

  test('pollOrgOverlay: windows working/routes, counts today', () async {
    final tmp = Directory.systemTemp.createTempSync('org_overlay_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    final ws = init.registries.workspace;
    await ws.create(type: WorkspaceType.org, slug: 'dev', title: 'Dev');

    final now = DateTime.now();
    final facts = init.registries.knowledge.knowledgeSystem.facts;
    Future<void> fact(String type, Map<String, dynamic> content, DateTime at,
        String id) {
      return facts.writeFacts([
        bundle.FactRecord(
          id: id,
          workspaceId: 'org/dev',
          type: type,
          entityId: '${content['agentId'] ?? content['targetAgentId']}',
          content: content,
          confidence: 1.0,
          createdAt: at,
        ),
      ]);
    }

    // Working window: 30s-old counts, 10min-old does not (but still today).
    await fact('agent.invoked', {'agentId': 'a-fresh'},
        now.subtract(const Duration(seconds: 30)), 'inv/1');
    await fact('agent.invoked', {'agentId': 'a-stale'},
        now.subtract(const Duration(minutes: 10)), 'inv/2');
    // Yesterday: neither working nor today's output.
    await fact('agent.invoked', {'agentId': 'a-old'},
        now.subtract(const Duration(days: 1)), 'inv/3');
    // Routes: in-window and out-of-window.
    await fact(
        'agent.routed',
        {'fromAgentId': 'lead', 'targetAgentId': 'a-fresh'},
        now.subtract(const Duration(seconds: 20)),
        'rt/1');
    await fact(
        'agent.routed',
        {'fromAgentId': 'lead', 'targetAgentId': 'a-stale'},
        now.subtract(const Duration(minutes: 5)),
        'rt/2');

    final data = await pollOrgOverlay(init);

    expect(data.workingAgentIds, contains('a-fresh'));
    expect(data.workingAgentIds, isNot(contains('a-stale')));
    expect(data.workingAgentIds, isNot(contains('a-old')));
    // Both non-yesterday invocations happened today (10min < a day and the
    // test never runs across midnight boundaries long enough to matter).
    expect(data.outputTodayByUnit['org/dev'], 2);
    expect(data.routes, hasLength(1));
    expect(data.routes.single.toId, 'a-fresh');
    expect(data.pendingByUnit, isEmpty);
  });
}
