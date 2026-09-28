/// `skill_save` announces a workspace skill only once it is in the runtime
/// pool. The Skills page's Integrated tab re-lists on the skill registry's
/// change event and reads the runtime pool; the event used to fire before
/// the pool registration, so the tab re-listed "0 pool" next to a Pool tab
/// that already showed the skill, and nothing re-listed it afterwards.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart'
    show SkillBundle, SkillManifest;
import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/tools/system_tools.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flowbrain_core/flowbrain_core.dart' show AgentAxis;
import 'package:flutter_test/flutter_test.dart';

Future<
  (
    KnowledgeInit,
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>),
  )
>
_boot() async {
  final tmp = await Directory.systemTemp.createTemp('skill_pool_order_');
  addTearDown(() => tmp.delete(recursive: true));
  final init = await KnowledgeInit.boot(
    OpsConfig(
      version: 'test',
      appName: 'test',
      activeWorkspace: '_system',
      workspacesRoot: tmp.path,
      llm: const LlmSettings.empty(),
      mcp: const McpSettings.defaults(),
      browser: const BrowserSettings.defaults(),
      storage: StorageSettings(localKvPath: '${tmp.path}/.kv'),
      channel: const ChannelSettings.empty(),
      security: const SecuritySettings.defaults(),
    ),
  );
  expect(init.system.isAgentSubsystemActivated, isTrue);
  final host = mk.InProcessKernelServerHost(name: 'ops', version: '0');
  SystemTools(init: init).registerOn(BuiltinToolRegistry(host));
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> a) async {
    final r = await host.callTool(name, a);
    return jsonDecode(
          r.content.whereType<mk.KernelTextContent>().map((c) => c.text).join(),
        )
        as Map<String, dynamic>;
  }

  return (init, call);
}

Future<List<String>> _pool(KnowledgeInit init, String wsId) async => [
  for (final e in await init.system.agents.listIntegrated(
    wsId,
    AgentAxis.skill,
  ))
    if (e.isPool) e.displayLabel,
];

void main() {
  _deleteTests();

  test('the change event sees the skill in the integrated pool', () async {
    final (init, call) = await _boot();
    await call('workspace_create', {'type': 'project', 'slug': 'pool'});
    await call('workspace_switch', {'id': 'project/pool'});

    // What the Integrated tab does on the event: re-list the pool.
    final seen = Completer<List<String>>();
    final sub = init.skills.changes.listen((_) async {
      if (seen.isCompleted) return;
      seen.complete(await _pool(init, 'project/pool'));
    });
    addTearDown(sub.cancel);

    final saved = await call('skill_save', {
      'yaml': 'id: greet\nversion: 1\ndescription: say hi\n',
      'scope': 'workspace',
    });
    expect(saved['saved'], isTrue, reason: '$saved');
    final pool = await seen.future.timeout(const Duration(seconds: 5));
    expect(pool.any((l) => l.contains('greet')), isTrue, reason: '$pool');
  });
}

void _deleteTests() {
  test('a deleted skill leaves the integrated pool', () async {
    final (init, call) = await _boot();
    await call('workspace_create', {'type': 'project', 'slug': 'a'});
    await call('workspace_switch', {'id': 'project/a'});
    await call('skill_save', {
      'yaml': 'id: greet\nversion: 1\ndescription: say hi\n',
      'scope': 'workspace',
    });
    expect(
      (await _pool(init, 'project/a')).any((l) => l.contains('greet')),
      isTrue,
    );
    // What the workspace loader registers at boot for the same skill.
    await init.system.skillRuntime!.registry.registerSkill(
      SkillBundle(
        schemaVersion: '0.1.0',
        manifest: SkillManifest(
          id: 'greet',
          name: 'greet',
          version: '1',
          provider: 'makemind-ops',
        ),
        procedures: const [],
      ),
    );
    final del = await call('skill_delete', {
      'id': 'greet',
      'scope': 'workspace',
    });
    expect(del['deleted'], isTrue, reason: '$del');
    expect(await _pool(init, 'project/a'), isNot(contains(contains('greet'))));
  });

  test('an id another workspace still authors stays pooled', () async {
    final (init, call) = await _boot();
    for (final ws in ['a', 'b']) {
      await call('workspace_create', {'type': 'project', 'slug': ws});
      await call('workspace_switch', {'id': 'project/$ws'});
      await call('skill_save', {
        'yaml': 'id: greet\nversion: 1\ndescription: say hi\n',
        'scope': 'workspace',
      });
    }
    await call('skill_delete', {'id': 'greet', 'scope': 'workspace'});
    expect(
      (await _pool(init, 'project/a')).any((l) => l.contains('greet')),
      isTrue,
    );
  });
}
