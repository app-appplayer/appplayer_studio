/// Org delete charter semantics — integration over a real `KnowledgeInit.boot`.
///
/// WS4 — `workspace_delete mode:purge` must delete the workspace's charter
/// ethos so a purged org leaves no governing doctrine behind. The deletion
/// rides `EthosStoreDelete` (mcp_bundle >= 0.4.6); if the Ops-wired store were
/// NOT delete-capable (e.g. a transitive mcp_philosophy without the impl — the
/// exact trap that shipped once), purge would SILENTLY skip cleanup.
///
/// WS2 — a workspace's active context loads its own charter plus every LIVE
/// ancestor's charter. An archived (deactivated-but-retained) ancestor's
/// charter must NOT leak into a live descendant's effective prohibitions.
///
///   e1  the Ops-wired ethos store is delete-capable (EthosStoreDelete)
///   e2  deleting a workspace's charter removes it from the store
///   a1  a LIVE ancestor's charter governs the descendant
///   a2  after the ancestor is archived, its charter is EXCLUDED
///   a3  reactivating the ancestor restores its charter to the descendant
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/init/workspace_loader.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_executor.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;

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

/// Mirrors `workspace_set_charter`'s ethos shape — one hard prohibition.
Future<void> _setCharter(
  KnowledgeInit init, {
  required String wsId,
  required String statement,
}) async {
  final now = DateTime.now();
  final id = 'charter.$wsId';
  final ethos = mb.Ethos(
    id: id,
    name: '$wsId charter',
    valuePriorities: const [],
    prohibitions: [
      mb.Prohibition(
        id: 'charter_p0',
        statement: statement,
        severity: mb.ProhibitionSeverity.hard,
        rationale: 'org charter',
        forbiddenPatterns: const [],
      ),
    ],
    metadata: mb.EthosMetadata(
      version: '1',
      createdAt: now,
      updatedAt: now,
      tags: const ['charter', 'anchor'],
    ),
  );
  await init.ethosStore!.putEthos(
    mb.EthosRecord(
      id: id,
      name: ethos.name,
      version: '1',
      payload: ethos.toJson(),
      createdAt: now,
    ),
  );
  await init.ethosStore!.activateEthos(id);
}

WorkspaceLoader _loader(KnowledgeInit init, OpsConfig cfg) => WorkspaceLoader(
  config: cfg,
  registries: init.registries,
  system: init.system,
  appSkills: AppSkillRegistry(),
  executor: SkillExecutor(system: init.system),
  ethosStore: init.ethosStore!,
);

void main() {
  late Directory tmp;
  late OpsConfig cfg;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('org_delete_charter_');
    cfg = _bound(tmp.path);
  });
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  // ── WS4 — purge deletes the charter ethos ────────────────────────────────
  group('WS4 charter ethos delete on purge', () {
    test('e1 the Ops-wired ethos store is delete-capable', () async {
      final init = await KnowledgeInit.boot(cfg);
      expect(init.ethosStore, isNotNull);
      // Regression guard: a store that is NOT EthosStoreDelete makes the
      // purge branch silently skip charter cleanup.
      expect(init.ethosStore, isA<mb.EthosStoreDelete>());
    });

    test('e2 deleting a workspace charter removes it from the store', () async {
      final init = await KnowledgeInit.boot(cfg);
      await init.registries.workspace.create(
        type: WorkspaceType.org,
        slug: 'gone',
        title: 'Gone',
      );
      const charterId = 'charter.org/gone';
      await _setCharter(init, wsId: 'org/gone', statement: 'No advertorial');
      expect(await init.ethosStore!.getEthos(charterId), isNotNull);

      // Exactly the purge-branch wiring in system_tools.workspace_delete.
      final store = init.ethosStore!;
      expect(store, isA<mb.EthosStoreDelete>());
      await (store as mb.EthosStoreDelete).deleteEthos(charterId);

      expect(await init.ethosStore!.getEthos(charterId), isNull);
    });
  });

  // ── WS2 — archived ancestor charter must not govern a live descendant ─────
  group('WS2 archived ancestor charter filter', () {
    test(
      'a1/a2/a3 live ancestor governs; archived excluded; reactivate restores',
      () async {
        final init = await KnowledgeInit.boot(cfg);
        final ws = init.registries.workspace;
        await ws.create(
          type: WorkspaceType.org,
          slug: 'parent',
          title: 'Parent',
        );
        await ws.create(
          type: WorkspaceType.org,
          slug: 'child',
          title: 'Child',
        );
        await ws.setParent('org/child', 'org/parent');
        await _setCharter(init, wsId: 'org/parent', statement: 'PARENT_RULE');

        final loader = _loader(init, cfg);

        // a1 — a live ancestor's charter governs the descendant.
        expect(
          await loader.effectiveHardProhibitions('org/child'),
          contains('PARENT_RULE'),
        );

        // a2 — archive the parent → its charter is excluded from the live child.
        await ws.deactivate('org/parent');
        expect(
          await loader.effectiveHardProhibitions('org/child'),
          isNot(contains('PARENT_RULE')),
        );

        // a3 — reactivate → the charter governs again.
        await ws.reactivate('org/parent');
        expect(
          await loader.effectiveHardProhibitions('org/child'),
          contains('PARENT_RULE'),
        );
      },
    );
  });
}
