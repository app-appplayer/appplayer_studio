/// A task's free text survives the YAML file. `ask-async-*` tasks store a
/// delegated message as their description — numbered lines, `: `, quotes —
/// and written bare it broke the file ("Expected ':'"), so the task vanished
/// on the next load.
library;

import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart' show KnowledgeSystem;
import 'package:appplayer_studio/src/apps/ops/registries/task_registry.dart';
import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

TaskRegistry _registry(String root) => TaskRegistry(
  kv: KvStoragePortAdapter(rootDir: p.join(root, 'kv')),
  knowledgeSystem: KnowledgeSystem.stub(),
  rootDir: root,
);

void main() {
  test('multi-line free text round-trips through a fresh load', () async {
    final tmp = await Directory.systemTemp.createTemp('task_yaml_quoting_');
    addTearDown(() => tmp.delete(recursive: true));

    const description =
        '다음 두 가지를 확인해 주세요:\n'
        '1. 정본 콘티의 현재 판(개정 이력)과 마지막 수정일.\n'
        '2. 관찰 불일치(증상만 기재): "S1 정본" — #표기 확인\n'
        '- 목록처럼 시작하는 줄\n'
        'tab\there \\ backslash';
    const title = 'Report: "S1" status # check';

    await _registry(tmp.path).create(
      Task(
        id: 'ask-async-1',
        workspaceId: 'org/newsroom',
        kind: TaskKind.oneOff,
        title: title,
        description: description,
        assigneeIds: const ['reporter'],
        skillIds: const [],
        inputs: const {'note': 'line one\nline two: with colon'},
        createdAt: DateTime.utc(2026, 9, 14),
      ),
    );

    final reloaded = await _registry(tmp.path).list(wsId: 'org/newsroom');
    expect(reloaded, hasLength(1), reason: 'the task file no longer loads');
    expect(reloaded.single.title, title);
    expect(reloaded.single.description, description);
    expect(reloaded.single.inputs['note'], 'line one\nline two: with colon');
  });
}
