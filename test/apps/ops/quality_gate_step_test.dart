/// The behavior step a process quality gate compiles to hands the appraisal
/// what the gated step produced.
library;

import 'package:appplayer_studio/src/apps/ops/tools/system_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_knowledge/mcp_knowledge.dart'
    show BehaviorAction, BehaviorEngine, BehaviorStep, EphemeralStateStore;

Map<String, dynamic> step({String stepId = 'draft', String assignee = 'ann'}) =>
    qualityEvalStep(
      evalId: 'eval',
      skill: 'quality_appraise',
      metric: 'clarity',
      assigneeId: assignee,
      stepId: stepId,
      dependsOn: 'draft',
    );

void main() {
  test('the appraisal gets the metric, the actor and the step output', () {
    final inputs = (step()['do'] as Map)['inputs'] as Map;
    expect(inputs, {'metric': 'clarity', 'actor': 'ann', 'prev': r'${draft}'});
  });

  test('no assignee: no actor', () {
    final inputs = (step(assignee: '')['do'] as Map)['inputs'] as Map;
    expect(inputs.containsKey('actor'), isFalse);
  });

  test('a step id that is not a path is left out, not sent as text', () {
    for (final id in ['draft-1', '1st', 'a b', 'a.b', '']) {
      final inputs = (step(stepId: id)['do'] as Map)['inputs'] as Map;
      expect(inputs.containsKey('prev'), isFalse, reason: id);
    }
  });

  test('the engine fills prev from the step that ran before', () async {
    final seen = <String, Map<String, dynamic>>{};
    final engine = BehaviorEngine(
      store: EphemeralStateStore(),
      dispatch: (BehaviorAction action, Map<String, dynamic> state) async {
        seen[action.ref] = action.args;
        return action.ref == 'work'
            ? <String, dynamic>{'text': 'the draft'}
            : <String, dynamic>{'score': 0.9};
      },
    );
    final evalDo = (step()['do'] as Map);
    await engine.run('r', [
      BehaviorStep(
        id: 'draft',
        action: BehaviorAction(kind: 'tool', ref: 'work'),
      ),
      BehaviorStep(
        id: 'eval',
        action: BehaviorAction(
          kind: 'tool',
          ref: evalDo['skill'] as String,
          args: Map<String, dynamic>.from(evalDo['inputs'] as Map),
        ),
      ),
    ], const <String, dynamic>{});
    expect(seen['quality_appraise']!['prev'], {'text': 'the draft'});
    expect(seen['quality_appraise']!['metric'], 'clarity');
  });
}
