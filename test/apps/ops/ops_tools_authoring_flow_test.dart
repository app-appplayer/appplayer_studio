/// Ops authoring driven the way an external LLM drives it: only tool calls
/// through the host registry, over a real `KnowledgeInit.boot` project.
/// Each step reads back what the previous one wrote.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/tools/system_tools.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late mk.InProcessKernelServerHost host;

  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final r = await host.callTool(name, args);
    final body =
        jsonDecode(
              r.content
                  .whereType<mk.KernelTextContent>()
                  .map((c) => c.text)
                  .join(),
            )
            as Map<String, dynamic>;
    return <String, dynamic>{...body, r'$isError': r.isError == true};
  }

  Future<Map<String, dynamic>> ok(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final body = await call(name, args);
    expect(body[r'$isError'], isFalse, reason: '$name: $body');
    return body;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ops_flow_');
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
    host = mk.InProcessKernelServerHost(name: 'ops', version: '0');
    SystemTools(init: init).registerOn(BuiltinToolRegistry(host));
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('workspace, charter and members round-trip through tools', () async {
    expect(
      (await ok('workspace_create', {
        'type': 'org',
        'slug': 'sales',
        'title': 'Sales',
      }))['id'],
      'org/sales',
    );
    await ok('workspace_switch', {'id': 'org/sales'});
    final listed = await ok('workspace_list');
    expect(listed['activeId'], 'org/sales');
    expect((listed['workspaces'] as List).map((w) => w['id']), [
      'org/sales',
    ]);

    await ok('workspace_set_charter', {
      'mission': 'Sell',
      'values': ['honest'],
    });
    final charter = (await ok('workspace_get_charter'))['charter'] as Map;
    expect(charter['mission'], 'Sell');
    expect(charter['values'], ['honest']);

    await ok('member_add_person', {'id': 'kim', 'displayName': 'Kim'});
    await ok('member_update', {'id': 'kim', 'displayName': 'Kim Lee'});
    final members = (await ok('member_list'))['members'] as List;
    expect(members.single['displayName'], 'Kim Lee');
    await ok('member_delete', {'id': 'kim'});
    expect((await ok('member_list'))['members'], isEmpty);
  });

  test('workspace_switch refuses an unknown or archived workspace', () async {
    await ok('workspace_create', {'type': 'org', 'slug': 'sales'});
    await ok('workspace_switch', {'id': 'org/sales'});

    final unknown = await call('workspace_switch', {'id': 'org/none'});
    expect(unknown[r'$isError'], isTrue);
    expect(unknown['error'], contains('workspace not found'));

    await ok('workspace_create', {'type': 'org', 'slug': 'old'});
    await ok('workspace_delete', {'id': 'org/old'});
    final archived = await call('workspace_switch', {'id': 'org/old'});
    expect(archived[r'$isError'], isTrue);
    expect(archived['error'], contains('archived'));

    // The active workspace is unchanged by a refused switch.
    expect((await ok('workspace_list'))['activeId'], 'org/sales');
  });

  test('skills and tasks round-trip through tools', () async {
    await ok('workspace_create', {'type': 'org', 'slug': 'ops'});
    await ok('workspace_switch', {'id': 'org/ops'});
    await ok('skill_save', {
      'yaml': 'id: greet\nname: Greet\ndescription: say hi\n',
      'scope': 'workspace',
    });
    expect((await ok('skill_get', {'id': 'greet'}))['description'], 'say hi');

    await ok('task_create', {
      'id': 't1',
      'title': 'Call',
      'skillIds': ['greet'],
    });
    await ok('task_update', {'id': 't1', 'state': 'completed'});
    expect((await ok('task_get', {'id': 't1'}))['state'], 'completed');

    // A state outside the declared enum is refused before the handler.
    final bad = await call('task_update', {'id': 't1', 'state': 'done'});
    expect(bad[r'$isError'], isTrue);
    expect(bad['code'], 'invalidArguments');

    await ok('task_delete', {'id': 't1'});
    expect((await ok('task_list'))['tasks'], isEmpty);
    await ok('skill_delete', {'id': 'greet', 'scope': 'workspace'});
    expect((await ok('skill_list'))['skills'], isEmpty);
  });

  test('knowledge facts and files round-trip through tools', () async {
    await ok('workspace_create', {'type': 'org', 'slug': 'kb'});
    await ok('workspace_switch', {'id': 'org/kb'});
    await ok('knowledge_fact_save', {
      'category': 'product',
      'key': 'price',
      'value': '10 USD',
    });
    final facts =
        (await ok('knowledge_fact_query', {'question': 'price'}))['facts']
            as List;
    expect(
      facts.any((f) => jsonEncode(f).contains('10 USD')),
      isTrue,
    );

    await ok('knowledge_file_write', {
      'path': 'knowledge/notes/a.md',
      'content': '# A',
    });
    final read = await ok('knowledge_file_read', {
      'path': 'knowledge/notes/a.md',
    });
    expect(jsonEncode(read), contains('# A'));
    await ok('knowledge_file_delete', {'path': 'knowledge/notes/a.md'});

    // A refused path is an error the caller can see from the flag alone.
    final refused = await call('knowledge_file_write', {
      'path': 'notes/a.md',
      'content': 'x',
    });
    expect(refused[r'$isError'], isTrue);
    expect(refused['error'], contains('knowledge/'));
  });

  test('rename, archive and restore a workspace through tools', () async {
    await ok('workspace_create', {'type': 'org', 'slug': 'sales'});
    await ok('workspace_rename', {'oldId': 'org/sales', 'newId': 'org/rev'});
    await ok('workspace_delete', {'id': 'org/rev'});
    expect((await ok('workspace_list'))['workspaces'], isEmpty);
    final archived =
        (await ok('workspace_list', {'includeArchived': true}))['workspaces']
            as List;
    expect(archived.single['archived'], isTrue);
    await ok('workspace_restore', {'id': 'org/rev'});
    final back = (await ok('workspace_list'))['workspaces'] as List;
    expect(back.single['id'], 'org/rev');
    expect(back.single['archived'], isFalse);
  });
}
