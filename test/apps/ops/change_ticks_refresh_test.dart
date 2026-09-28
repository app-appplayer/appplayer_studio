/// Ops lists refresh on every registry mutation, not only the first.
///
/// The list providers `ref.watch` a change stream. Riverpod skips an update
/// whose value equals the previous one, so a stream of `void` events
/// notified once and then went silent: a task or workspace created after the
/// first change appeared, but a later delete never left the list.
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/registries/task_registry.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';
import 'package:appplayer_studio/src/apps/ops/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
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

Task _task(String id, String wsId) => Task(
  id: id,
  workspaceId: wsId,
  kind: TaskKind.oneOff,
  title: id,
  assigneeIds: const <String>[],
  skillIds: const <String>['s'],
  createdAt: DateTime.now(),
);

/// Waits until [provider] resolves to a value satisfying [test].
Future<T> _settle<T>(
  ProviderContainer c,
  ProviderListenable<AsyncValue<T>> provider,
  bool Function(T) test,
) async {
  for (var i = 0; i < 100; i++) {
    final v = c.read(provider);
    if (v.hasValue && test(v.requireValue)) return v.requireValue;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return c.read(provider).requireValue;
}

void main() {
  test('changeTicks gives every event a distinct value', () async {
    final events = Stream<void>.fromIterable(<void>[null, null, null]);
    expect(await changeTicks(events).toList(), <int>[1, 2, 3]);
  });

  test('task list follows create → create → delete → delete', () async {
    final tmp = Directory.systemTemp.createTempSync('ops_ticks_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    final ws = await init.registries.workspace.create(
      type: WorkspaceType.project,
      slug: 'qa',
      title: 'QA',
    );
    final c = ProviderContainer(
      overrides: [knowledgeInitProvider.overrideWithValue(init)],
    );
    addTearDown(c.dispose);
    final tasks = workspaceTasksProvider(ws.id);
    c.listen(tasks, (_, _) {});
    List<String> ids(List<Task> l) => [for (final t in l) t.id]..sort();

    await _settle(c, tasks, (l) => l.isEmpty);
    await init.registries.task.create(_task('a', ws.id));
    expect(ids(await _settle(c, tasks, (l) => l.length == 1)), ['a']);
    await init.registries.task.create(_task('b', ws.id));
    expect(ids(await _settle(c, tasks, (l) => l.length == 2)), ['a', 'b']);
    await init.registries.task.delete('a');
    expect(ids(await _settle(c, tasks, (l) => l.length == 1)), ['b']);
    await init.registries.task.delete('b');
    expect(await _settle(c, tasks, (l) => l.isEmpty), isEmpty);
  });

  test('workspace list drops a deleted workspace', () async {
    final tmp = Directory.systemTemp.createTempSync('ops_ticks_ws_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    final c = ProviderContainer(
      overrides: [knowledgeInitProvider.overrideWithValue(init)],
    );
    addTearDown(c.dispose);
    c.listen(workspaceListProvider, (_, _) {});
    bool has(List<Workspace> l, String id) => l.any((w) => w.id == id);

    final one = await init.registries.workspace.create(
      type: WorkspaceType.project,
      slug: 'one',
      title: 'One',
    );
    await _settle(c, workspaceListProvider, (l) => has(l, one.id));
    final two = await init.registries.workspace.create(
      type: WorkspaceType.project,
      slug: 'two',
      title: 'Two',
    );
    await _settle(c, workspaceListProvider, (l) => has(l, two.id));
    await init.registries.workspace.delete(one.id);
    final after = await _settle(
      c,
      workspaceListProvider,
      (l) => !has(l, one.id),
    );
    expect(has(after, one.id), isFalse);
    expect(has(after, two.id), isTrue);
  });

  test('Home fact count and recent knowledge follow saves', () async {
    final tmp = Directory.systemTemp.createTempSync('ops_ticks_kn_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    await init.registries.workspace.create(
      type: WorkspaceType.project,
      slug: 'kn',
      title: 'Kn',
    );
    await init.registries.workspace.setActive('project/kn');
    final c = ProviderContainer(
      overrides: [knowledgeInitProvider.overrideWithValue(init)],
    );
    addTearDown(c.dispose);
    c.listen(knowledgeCountsProvider, (_, _) {});
    c.listen(recentKvFactsProvider, (_, _) {});

    await _settle(c, knowledgeCountsProvider, (k) => k.facts == 0);
    await init.registries.knowledge.saveFact(
      category: 'policy',
      key: 'refund',
      value: '14 days',
    );
    expect(
      (await _settle(c, knowledgeCountsProvider, (k) => k.facts == 1)).facts,
      1,
    );
    await init.registries.knowledge.saveFact(
      category: 'policy',
      key: 'shipping',
      value: '3 days',
    );
    expect(
      (await _settle(c, knowledgeCountsProvider, (k) => k.facts == 2)).facts,
      2,
    );
    expect(
      await _settle(c, recentKvFactsProvider, (l) => l.length == 2),
      hasLength(2),
    );
  });
}
