/// A skill's `fact.query` reads the workspace the run is pinned to — the one
/// its `fact.save` writes to — unless the step names one.
library;

import 'package:appplayer_studio/builtin_api.dart' show KnowledgeSystem;
import 'package:appplayer_studio/src/apps/ops/init/workspace_context.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_definition.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_executor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as bundle;

Future<void> save(KnowledgeSystem system, String ws, String id) =>
    system.facts.writeFacts(<bundle.FactRecord>[
      bundle.FactRecord(
        id: id,
        workspaceId: ws,
        type: 'note',
        content: <String, dynamic>{'text': id},
        createdAt: DateTime(2026),
      ),
    ]);

SkillDefinition query([Map<String, dynamic> inputs = const {}]) =>
    SkillDefinition.fromYaml({
      'id': 'q',
      'actionBody': {'kind': 'fact.query', 'inputs': inputs},
    });

void main() {
  test('the pinned workspace, not another one', () async {
    final system = KnowledgeSystem.stub();
    await save(system, 'org/a', 'in_a');
    await save(system, 'org/b', 'in_b');
    final exec = SkillExecutor(system: system);
    final r = await WorkspaceExecutionContext.run(
      'org/a',
      () => exec.run(query(), {}),
    );
    expect((r['facts'] as List).map((f) => (f as Map)['id']), ['in_a']);
  });

  test('a workspace the step names wins over the pinned one', () async {
    final system = KnowledgeSystem.stub();
    await save(system, 'org/a', 'in_a');
    await save(system, 'org/b', 'in_b');
    final exec = SkillExecutor(system: system);
    final r = await WorkspaceExecutionContext.run(
      'org/a',
      () => exec.run(query({'workspaceId': 'org/b'}), {}),
    );
    expect((r['facts'] as List).map((f) => (f as Map)['id']), ['in_b']);
  });
}
