/// Unit tests for `SkillDefinition.fromYaml` and related models.
///
/// Boot-independent: pure data model parse logic.
///
/// Scenarios:
///   sd1  fromYaml parses id / version / description
///   sd2  fromYaml accepts 'action' alias for 'actionBody'
///   sd3  fromYaml version coercion — int / num / string / missing
///   sd4  fromYaml budget parsed when present
///   sd5  fromYaml budget is null when absent
///   sd6  fromYaml tags parsed correctly
///   sd7  ActionBody.fromYaml — kind / steps / data / inputs
///   sd8  ActionBody.fromYaml with null/non-map input → kind='noop'
///   sd9  ActionStep.fromYaml — shorthand (no explicit data: block)
///   sd10 ActionStep.fromYaml — explicit data: block takes precedence
///   sd11 SkillBudget.fromYaml — llmTokens / timeMs
///   sd12 composite action with multiple steps is parsed correctly
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_definition.dart';

Map<String, dynamic> _minSkill({
  String id = 'test.skill',
  dynamic version = 1,
  dynamic actionBody,
}) => <String, dynamic>{
  'id': id,
  'version': version,
  'description': 'A test skill',
  if (actionBody != null) 'actionBody': actionBody,
};

void main() {
  group('SkillDefinition.fromYaml', () {
    // sd1
    test('sd1 parses id / version / description', () {
      final skill = SkillDefinition.fromYaml(
        _minSkill(id: 'my.skill', version: 2),
      );
      expect(skill.id, 'my.skill');
      expect(skill.version, 2);
      expect(skill.description, 'A test skill');
    });

    // sd2
    test('sd2 accepts action alias for actionBody', () {
      final y = <String, dynamic>{
        'id': 'alias.skill',
        'version': 1,
        'description': 'Uses action alias',
        'action': <String, dynamic>{'kind': 'llm'},
      };
      final skill = SkillDefinition.fromYaml(y);
      expect(skill.actionBody.kind, 'llm');
    });

    // sd3 — version coercion
    group('sd3 version coercion', () {
      test('int → int', () {
        final s = SkillDefinition.fromYaml(_minSkill(version: 3));
        expect(s.version, 3);
      });

      test('double → int via toInt()', () {
        final s = SkillDefinition.fromYaml(_minSkill(version: 2.0));
        expect(s.version, 2);
      });

      test('string → parsed int', () {
        final s = SkillDefinition.fromYaml(_minSkill(version: '5'));
        expect(s.version, 5);
      });

      test('invalid string → 1 (fallback)', () {
        final s = SkillDefinition.fromYaml(_minSkill(version: 'abc'));
        expect(s.version, 1);
      });

      test('null → 1 (fallback)', () {
        final y = <String, dynamic>{'id': 'x', 'description': ''};
        final s = SkillDefinition.fromYaml(y);
        expect(s.version, 1);
      });
    });

    // sd4
    test('sd4 budget parsed when present', () {
      final y = <String, dynamic>{
        'id': 'budgeted',
        'version': 1,
        'description': '',
        'budget': <String, dynamic>{'llmTokens': 2000, 'timeMs': 5000},
      };
      final skill = SkillDefinition.fromYaml(y);
      expect(skill.budget, isNotNull);
      expect(skill.budget!.llmTokens, 2000);
      expect(skill.budget!.timeMs, 5000);
    });

    // sd5
    test('sd5 budget is null when absent', () {
      final skill = SkillDefinition.fromYaml(_minSkill());
      expect(skill.budget, isNull);
    });

    // sd6
    test('sd6 tags parsed correctly', () {
      final y = <String, dynamic>{
        'id': 'tagged',
        'version': 1,
        'description': '',
        'tags': <String>['research', 'summary'],
      };
      final skill = SkillDefinition.fromYaml(y);
      expect(skill.tags, <String>['research', 'summary']);
    });

    test('sd6b tags default to empty when absent', () {
      final skill = SkillDefinition.fromYaml(_minSkill());
      expect(skill.tags, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // ActionBody
  // ---------------------------------------------------------------------------
  group('ActionBody.fromYaml', () {
    // sd7
    test('sd7 parses kind / steps / data / inputs', () {
      final raw = <String, dynamic>{
        'kind': 'composite',
        'data': <String, dynamic>{'model': 'claude-sonnet'},
        'inputs': <String, dynamic>{'topic': 'ai'},
        'steps': <dynamic>[
          <String, dynamic>{'kind': 'llm', 'id': 'step1'},
        ],
      };
      final ab = ActionBody.fromYaml(raw);
      expect(ab.kind, 'composite');
      expect(ab.data['model'], 'claude-sonnet');
      expect(ab.inputs['topic'], 'ai');
      expect(ab.steps, hasLength(1));
      expect(ab.steps.first.kind, 'llm');
    });

    // sd8
    test('sd8 null / non-map input → kind noop', () {
      expect(ActionBody.fromYaml(null).kind, 'noop');
      expect(ActionBody.fromYaml('string').kind, 'noop');
      expect(ActionBody.fromYaml(42).kind, 'noop');
    });

    test('sd8b missing kind → noop', () {
      final ab = ActionBody.fromYaml(<String, dynamic>{});
      expect(ab.kind, 'noop');
    });
  });

  // ---------------------------------------------------------------------------
  // ActionStep
  // ---------------------------------------------------------------------------
  group('ActionStep.fromYaml', () {
    // sd9 — shorthand (no data block; top-level keys become data)
    test('sd9 shorthand form puts remaining keys into data', () {
      final raw = <String, dynamic>{
        'kind': 'llm',
        'id': 'ask_llm',
        'output': 'result',
        'prompt': 'Summarise this',
        'temperature': 0.8,
      };
      final step = ActionStep.fromYaml(raw);
      expect(step.kind, 'llm');
      expect(step.id, 'ask_llm');
      expect(step.output, 'result');
      expect(step.data['prompt'], 'Summarise this');
      expect(step.data['temperature'], 0.8);
      // Standard keys should not leak into data
      expect(step.data.containsKey('kind'), isFalse);
      expect(step.data.containsKey('id'), isFalse);
    });

    // sd10 — explicit data block takes precedence
    test('sd10 explicit data block wins over shorthand', () {
      final raw = <String, dynamic>{
        'kind': 'browser',
        'data': <String, dynamic>{'url': 'https://example.com'},
        'url': 'should_be_ignored',
      };
      final step = ActionStep.fromYaml(raw);
      expect(step.data['url'], 'https://example.com');
    });

    test('sd10b inputs are extracted when present', () {
      final raw = <String, dynamic>{
        'kind': 'mcp',
        'inputs': <String, dynamic>{'target': 'tool.foo'},
      };
      final step = ActionStep.fromYaml(raw);
      expect(step.inputs['target'], 'tool.foo');
    });
  });

  // ---------------------------------------------------------------------------
  // SkillBudget
  // ---------------------------------------------------------------------------
  group('SkillBudget.fromYaml', () {
    // sd11
    test('sd11 parses llmTokens and timeMs', () {
      final budget = SkillBudget.fromYaml(<String, dynamic>{
        'llmTokens': 4096,
        'timeMs': 10000,
      });
      expect(budget.llmTokens, 4096);
      expect(budget.timeMs, 10000);
    });

    test('sd11b partial budget — only llmTokens', () {
      final budget = SkillBudget.fromYaml(<String, dynamic>{'llmTokens': 1000});
      expect(budget.llmTokens, 1000);
      expect(budget.timeMs, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // sd12: composite action
  // ---------------------------------------------------------------------------
  group('Composite action', () {
    test('sd12 multiple steps parsed in order', () {
      final raw = <String, dynamic>{
        'kind': 'composite',
        'steps': <dynamic>[
          <String, dynamic>{'kind': 'llm', 'id': 's1'},
          <String, dynamic>{'kind': 'browser', 'id': 's2'},
          <String, dynamic>{'kind': 'fact.save', 'id': 's3'},
        ],
      };
      final ab = ActionBody.fromYaml(raw);
      expect(ab.steps, hasLength(3));
      expect(ab.steps[0].kind, 'llm');
      expect(ab.steps[0].id, 's1');
      expect(ab.steps[1].kind, 'browser');
      expect(ab.steps[2].kind, 'fact.save');
    });
  });
}
