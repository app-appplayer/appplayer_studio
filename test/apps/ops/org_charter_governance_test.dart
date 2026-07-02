/// Org charter governance — PURPOSE proof, not a mechanism test.
///
/// The point of the charter is that the org's doctrine actually GOVERNS:
/// set it once on the (per-project) active ethos, and the per-project
/// philosophy check (which the process gate + opted-in agents route through)
/// blocks a forbidden output. If this fails, a `workspace_set_charter` tool
/// would be a charter that doesn't govern — implementation for its own sake.
///
///   c1  a charter prohibition with a forbidden pattern HARD-blocks a matching
///       output via the per-project `system.philosophy.checkProhibitions`
///   c2  a clean output passes
///   c3  before any charter is set, the check fails open (no governance to apply)
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
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

/// Mirrors `workspace_set_charter`'s ethos shape.
Future<void> _setCharter(
  KnowledgeInit init, {
  required String wsId,
  required List<({String statement, List<String> patterns})> prohibitions,
}) async {
  final now = DateTime.now();
  final id = 'charter.$wsId';
  final ethos = mb.Ethos(
    id: id,
    name: '$wsId charter',
    valuePriorities: const [],
    prohibitions: [
      for (var i = 0; i < prohibitions.length; i++)
        mb.Prohibition(
          id: 'charter_p$i',
          statement: prohibitions[i].statement,
          severity: mb.ProhibitionSeverity.hard,
          rationale: 'org charter',
          forbiddenPatterns: prohibitions[i].patterns,
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

Future<bool> _hardBlocked(KnowledgeInit init, String output) async {
  final r = await init.system.philosophy.checkProhibitions(
    mb.ProhibitionCheckRequest(proposedOutput: output),
  );
  return r.hasHardViolation;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('charter_gov_'));
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  test('c3 before a charter is set, check fails open', () async {
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    // No charter set yet → no governing prohibition → not blocked.
    expect(await _hardBlocked(init, 'anything goes ADVERTORIAL'), isFalse);
  });

  test('c1/c2 a charter pattern governs the per-project check', () async {
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    expect(init.ethosStore, isNotNull);
    await _setCharter(
      init,
      wsId: '_system',
      prohibitions: const [
        (statement: 'No advertorial content', patterns: ['ADVERTORIAL']),
      ],
    );
    // c1 — matching output is HARD-blocked by the charter.
    expect(await _hardBlocked(init, 'this is ADVERTORIAL fluff'), isTrue);
    // c2 — clean output passes.
    expect(await _hardBlocked(init, 'a sober, evidenced report'), isFalse);
  });
}
