/// Process gates are placed by `afterStep` + `kind`. A `gates:` entry the
/// engine cannot place used to be filled with defaults (`*` · philosophy) and
/// attached to no step — the gate silently did nothing. It is now rejected at
/// save with the reason. A run parked at a human step carries no pending
/// approval, so the approvals inbox does not offer an approved gate again.
library;

import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart' show KnowledgeSystem;
import 'package:appplayer_studio/src/apps/ops/infra/ws_paths.dart';
import 'package:appplayer_studio/src/apps/ops/registries/process_registry.dart';
import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _steps = '''
steps:
  - stepId: plan
    assigneeId: chief
    skillId: human
  - stepId: build
    assigneeId: reporter
    skillId: sk_build
''';

late String _root;

Future<ProcessRegistry> _registry() async {
  final tmp = await Directory.systemTemp.createTemp('proc_gate_yaml_');
  addTearDown(() => tmp.delete(recursive: true));
  _root = tmp.path;
  return ProcessRegistry(
    kv: KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv')),
    knowledgeSystem: KnowledgeSystem.stub(),
    rootDir: tmp.path,
  );
}

void main() {
  group('gates: entries', () {
    test('the canonical shape is accepted with its params', () async {
      final reg = await _registry();
      final proc = await reg.saveFromYaml('''
id: canon
$_steps
gates:
  - afterStep: plan
    kind: approval
    params: { approverId: publisher }
''', 'project/ws1');
      expect(proc.gates, hasLength(1));
      expect(proc.gates.single.afterStep, 'plan');
      expect(proc.gates.single.kind, GateKind.approval);
      expect(proc.gates.single.params['approverId'], 'publisher');
    });

    test('an entry without afterStep is rejected, not defaulted', () async {
      // The shape the seed knowledge used to teach.
      final reg = await _registry();
      expect(
        () => reg.saveFromYaml('''
id: no_after
$_steps
gates:
  - approverId: ops.manager
''', 'project/ws1'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('afterStep'), contains('plan, build')),
          ),
        ),
      );
    });

    test('stepId / type instead of afterStep / kind is rejected', () async {
      final reg = await _registry();
      expect(
        () => reg.saveFromYaml('''
id: wrong_keys
$_steps
gates:
  - stepId: plan
    type: approval
''', 'project/ws1'),
        throwsA(isA<StateError>()),
      );
    });

    test('afterStep naming no step is rejected', () async {
      final reg = await _registry();
      expect(
        () => reg.saveFromYaml('''
id: ghost_step
$_steps
gates:
  - afterStep: publish
    kind: approval
''', 'project/ws1'),
        throwsA(isA<StateError>()),
      );
    });

    test('an unknown kind is rejected', () async {
      final reg = await _registry();
      expect(
        () => reg.saveFromYaml('''
id: bad_kind
$_steps
gates:
  - afterStep: plan
    kind: signoff
''', 'project/ws1'),
        throwsA(isA<StateError>()),
      );
    });

    test('a rejected save writes no file', () async {
      final reg = await _registry();
      await expectLater(
        reg.saveFromYaml('''
id: not_written
$_steps
gates:
  - approverId: x
''', 'project/ws1'),
        throwsA(isA<StateError>()),
      );
      final file = File(
        '${wsContentRoot(_root, 'project/ws1')}/processes/not_written.yaml',
      );
      expect(await file.exists(), isFalse);
    });
  });

  group('isHumanStepWait', () {
    final proc = Process(
      id: 'p',
      workspaceId: 'project/ws1',
      title: 'p',
      steps: [
        ProcessStep(stepId: 'plan', assigneeId: 'chief', skillId: 'human'),
        ProcessStep(stepId: 'check', assigneeId: 'ed', skillId: 'manual'),
        ProcessStep(stepId: 'build', assigneeId: 'rep', skillId: 'sk_build'),
      ],
      gates: [
        ProcessGate(afterStep: 'build', kind: GateKind.approval, params: {}),
      ],
      trigger: ProcessTrigger.manual,
    );

    test('human and manual steps are work waits', () {
      expect(isHumanStepWait(proc, 'plan'), isTrue);
      expect(isHumanStepWait(proc, 'check'), isTrue);
    });

    test('a gate node, an agent step or no step is not', () {
      expect(isHumanStepWait(proc, 'gate_approval_build'), isFalse);
      expect(isHumanStepWait(proc, 'build'), isFalse);
      expect(isHumanStepWait(proc, ''), isFalse);
    });
  });
}
