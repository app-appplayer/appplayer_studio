/// SkillExecutor + SkillDefinition — unit tests for all pure-logic paths.
///
/// SkillExecutor methods that require a live LLM provider, host browser
/// capability, host ingest capability, or host MCP endpoint are SKIPPED with
/// notes. The following sub-systems are fully testable in isolation:
///
/// SkillDefinition / ActionBody / ActionStep parsing:
///   s1  SkillDefinition.fromYaml — id / description / version (int)
///   s2  SkillDefinition.fromYaml — version from string "2" and from num
///   s3  SkillDefinition.fromYaml — actionBody: null → noop ActionBody
///   s4  SkillDefinition.fromYaml — accepts `action:` shorthand alias
///   s5  SkillDefinition.fromYaml — inputSchema / outputSchema parsed
///   s6  SkillDefinition.fromYaml — budget parsed (llmTokens / timeMs)
///   s7  SkillDefinition.fromYaml — tags list preserved
///   s8  ActionBody.fromYaml — non-map input → kind='noop'
///   s9  ActionBody.fromYaml — composite with multiple steps
///   s10 ActionBody.fromYaml — data block parsed
///   s11 ActionStep.fromYaml — kind / id / output / inputs / data
///   s12 ActionStep.fromYaml — shorthand top-level keys become data
///   s13 SkillBudget.fromYaml — llmTokens / timeMs round-trip
///
/// SkillExecutor template resolution (_resolveString / _resolveValue):
///   s14 _resolveString resolves `{{in.field}}` from inputs map
///   s15 _resolveString resolves nested `{{step.step1.text}}`
///   s16 _resolveString returns empty string for unknown path
///   s17 _resolveValue — passes through int / bool / null unchanged
///   s18 _resolveValue — resolves within nested Map recursively
///   s19 _resolveValue — resolves within List recursively
///
/// SkillExecutor — map / noop steps:
///   s20 run with `kind: map` returns resolved inputs as `value`
///   s21 run with `kind: noop` returns empty map
///   s22 run throws StateError for unsupported kind
///
/// SkillExecutor — composite steps:
///   s23 composite step sequences steps and captures output slots
///   s24 composite with noop sub-steps returns last output (empty map)
///
/// SkillExecutor — fact.save (no knowledge registry attached):
///   s25 fact.save step calls system.facts.extractFragments (stub no-op)
///
/// SkillExecutor — binding / adapter API:
///   s26 hasAnyLlm is false when no adapters bound
///   s27 samplingProvider is null initially, non-null after attachSampling
///   s28 callHostTool throws StateError when not bound
///   s29 callHostToolJson decodes JSON text from host result
///
/// NOTE: _runLlm / _runBrowser / _runMcp / _runIngest / _runChannel require
/// host capabilities wired at OpsBuiltInApp.ensureBoot — all SKIPPED here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/builtin_api.dart'
    show KnowledgeSystem, KernelToolResult, KernelTextContent;
import 'package:appplayer_studio/src/apps/ops/skills/skill_definition.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_executor.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Minimal YAML map for a SkillDefinition with a single `kind: map` action.
Map<String, dynamic> _mapSkillYaml({
  String id = 'test_skill',
  Map<String, dynamic>? actionData,
}) => {
  'id': id,
  'version': 1,
  'description': 'A test skill',
  'actionBody': {
    'kind': 'map',
    'inputs': actionData ?? {'greeting': 'hello'},
  },
};

SkillExecutor _makeExecutor() => SkillExecutor(system: KnowledgeSystem.stub());

void main() {
  // ==========================================================================
  // SkillDefinition parsing
  // ==========================================================================
  group('SkillDefinition.fromYaml — parsing', () {
    // --- s1: basic fields ---
    test('s1 fromYaml parses id / description / version (int)', () {
      final def = SkillDefinition.fromYaml({
        'id': 'skill_alpha',
        'version': 3,
        'description': 'Does alpha things',
        'actionBody': {'kind': 'noop'},
      });
      expect(def.id, 'skill_alpha');
      expect(def.version, 3);
      expect(def.description, 'Does alpha things');
    });

    // --- s2: version coercion ---
    test('s2 fromYaml coerces version from String and num', () {
      final fromString = SkillDefinition.fromYaml({
        'id': 's',
        'version': '5',
        'actionBody': {'kind': 'noop'},
      });
      expect(fromString.version, 5);

      final fromDouble = SkillDefinition.fromYaml({
        'id': 's',
        'version': 2.0,
        'actionBody': {'kind': 'noop'},
      });
      expect(fromDouble.version, 2);
    });

    // --- s3: null action body → noop ---
    test('s3 fromYaml null actionBody produces noop ActionBody', () {
      final def = SkillDefinition.fromYaml({'id': 'no_action'});
      expect(def.actionBody.kind, 'noop');
    });

    // --- s4: `action:` shorthand ---
    test('s4 fromYaml accepts action: as alias for actionBody:', () {
      final def = SkillDefinition.fromYaml({
        'id': 'shorthand',
        'action': {
          'kind': 'map',
          'inputs': {'x': 1},
        },
      });
      expect(def.actionBody.kind, 'map');
    });

    // --- s5: inputSchema / outputSchema ---
    test('s5 fromYaml parses inputSchema and outputSchema', () {
      final def = SkillDefinition.fromYaml({
        'id': 'schema_skill',
        'inputSchema': {'prompt': 'string'},
        'outputSchema': {'text': 'string'},
        'actionBody': {'kind': 'noop'},
      });
      expect(def.inputSchema['prompt'], 'string');
      expect(def.outputSchema['text'], 'string');
    });

    // --- s6: budget ---
    test('s6 fromYaml parses budget with llmTokens and timeMs', () {
      final def = SkillDefinition.fromYaml({
        'id': 'budget_skill',
        'budget': {'llmTokens': 4000, 'timeMs': 30000},
        'actionBody': {'kind': 'noop'},
      });
      expect(def.budget, isNotNull);
      expect(def.budget!.llmTokens, 4000);
      expect(def.budget!.timeMs, 30000);
    });

    // --- s7: tags ---
    test('s7 fromYaml preserves tags list', () {
      final def = SkillDefinition.fromYaml({
        'id': 'tagged',
        'tags': ['content', 'draft', 'review'],
        'actionBody': {'kind': 'noop'},
      });
      expect(def.tags, containsAll(['content', 'draft', 'review']));
    });
  });

  group('ActionBody.fromYaml — parsing', () {
    // --- s8: non-map → noop ---
    test('s8 fromYaml non-map input produces noop ActionBody', () {
      final body = ActionBody.fromYaml(null);
      expect(body.kind, 'noop');

      final listBody = ActionBody.fromYaml(['not', 'a', 'map']);
      expect(listBody.kind, 'noop');
    });

    // --- s9: composite with multiple steps ---
    test('s9 fromYaml composite kind parses multiple steps', () {
      final body = ActionBody.fromYaml({
        'kind': 'composite',
        'steps': [
          {'kind': 'noop', 'id': 'step1'},
          {
            'kind': 'map',
            'id': 'step2',
            'inputs': {'v': 42},
          },
        ],
      });
      expect(body.kind, 'composite');
      expect(body.steps.length, 2);
      expect(body.steps[0].kind, 'noop');
      expect(body.steps[1].kind, 'map');
    });

    // --- s10: data block ---
    test('s10 fromYaml data block is parsed into ActionBody.data', () {
      final body = ActionBody.fromYaml({
        'kind': 'llm',
        'data': {'prompt': 'Summarize this', 'temperature': 0.7},
      });
      expect(body.kind, 'llm');
      expect(body.data['prompt'], 'Summarize this');
      expect(body.data['temperature'], 0.7);
    });
  });

  group('ActionStep.fromYaml — parsing', () {
    // --- s11: standard fields ---
    test('s11 fromYaml parses kind / id / output / inputs / data', () {
      final step = ActionStep.fromYaml({
        'kind': 'mcp',
        'id': 'fetch_step',
        'output': 'fetch_result',
        'inputs': {'query': 'revenue'},
        'data': {'server': 'my_mcp_server', 'tool': 'db.query'},
      });
      expect(step.kind, 'mcp');
      expect(step.id, 'fetch_step');
      expect(step.output, 'fetch_result');
      expect(step.inputs['query'], 'revenue');
      expect(step.data['server'], 'my_mcp_server');
      expect(step.data['tool'], 'db.query');
    });

    // --- s12: shorthand top-level keys → data ---
    test(
      's12 fromYaml shorthand top-level keys (no data block) become data',
      () {
        final step = ActionStep.fromYaml({
          'kind': 'llm',
          'prompt': 'Translate this',
          'temperature': 0.3,
          'maxTokens': 1000,
        });
        expect(step.kind, 'llm');
        expect(step.data['prompt'], 'Translate this');
        expect(step.data['temperature'], 0.3);
        expect(step.data['maxTokens'], 1000);
        // Reserved keys must not leak into data.
        expect(step.data.containsKey('kind'), isFalse);
      },
    );
  });

  group('SkillBudget.fromYaml', () {
    // --- s13 ---
    test('s13 fromYaml round-trip llmTokens and timeMs', () {
      final budget = SkillBudget.fromYaml({'llmTokens': 8000, 'timeMs': 60000});
      expect(budget.llmTokens, 8000);
      expect(budget.timeMs, 60000);
    });

    test('s13b fromYaml with missing fields produces nulls', () {
      final budget = SkillBudget.fromYaml({});
      expect(budget.llmTokens, isNull);
      expect(budget.timeMs, isNull);
    });
  });

  // ==========================================================================
  // SkillExecutor template resolution
  // ==========================================================================
  group('SkillExecutor — template resolution', () {
    // The _resolveString method is private; we test it via run() with kind:map
    // which calls _resolveMap → _resolveValue → _resolveString internally.

    // --- s14: resolves {{in.field}} ---
    test('s14 {{in.field}} resolves from inputs map', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'tmpl1',
        'actionBody': {
          'kind': 'map',
          'inputs': {'msg': '{{in.name}} says hello'},
        },
      });
      final result = await exec.run(def, {'name': 'Alice'});
      expect(result['value']['msg'], 'Alice says hello');
    });

    // --- s15: resolves nested {{step.step1.text}} ---
    test('s15 {{step.step1.text}} resolves from composite step output', () async {
      final exec = _makeExecutor();
      // Composite: step1=noop (output empty), step2=map references step1 result.
      // Since noop returns {} and {{step.step1.value}} is not in context,
      // we use a map step that stores its output and a second step reads it.
      final def = SkillDefinition.fromYaml({
        'id': 'tmpl2',
        'actionBody': {
          'kind': 'composite',
          'steps': [
            {
              'kind': 'map',
              'id': 's1',
              'output': 'step1',
              'inputs': {'text': 'from_step1'},
            },
            {
              'kind': 'map',
              'id': 's2',
              'inputs': {'combined': 'got: {{step.step1.value.text}}'},
            },
          ],
        },
      });
      final result = await exec.run(def, {});
      expect(result['value']['combined'], 'got: from_step1');
    });

    // --- s16: unknown path → empty string ---
    test('s16 {{unknown.path}} resolves to empty string', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'tmpl3',
        'actionBody': {
          'kind': 'map',
          'inputs': {'msg': 'value={{no.such.key}}'},
        },
      });
      final result = await exec.run(def, {});
      expect(result['value']['msg'], 'value=');
    });

    // --- s17: int/bool/null pass through ---
    test(
      's17 non-string values pass through _resolveValue unchanged',
      () async {
        final exec = _makeExecutor();
        final def = SkillDefinition.fromYaml({
          'id': 'tmpl4',
          'actionBody': {
            'kind': 'map',
            'inputs': {'count': 42, 'flag': true, 'nothing': null},
          },
        });
        final result = await exec.run(def, {});
        expect(result['value']['count'], 42);
        expect(result['value']['flag'], true);
        expect(result['value']['nothing'], isNull);
      },
    );

    // --- s18: nested map resolved recursively ---
    test('s18 nested map values are resolved recursively', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'tmpl5',
        'actionBody': {
          'kind': 'map',
          'inputs': {
            'outer': {'inner': '{{in.x}}'},
          },
        },
      });
      final result = await exec.run(def, {'x': 'resolved_x'});
      final outer = result['value']['outer'] as Map;
      expect(outer['inner'], 'resolved_x');
    });

    // --- s19: list resolved recursively ---
    test('s19 list values are resolved recursively', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'tmpl6',
        'actionBody': {
          'kind': 'map',
          'inputs': {
            'items': ['static', '{{in.dynamic}}', 99],
          },
        },
      });
      final result = await exec.run(def, {'dynamic': 'resolved'});
      final items = result['value']['items'] as List;
      expect(items[0], 'static');
      expect(items[1], 'resolved');
      expect(items[2], 99);
    });
  });

  // ==========================================================================
  // SkillExecutor — map / noop / unsupported
  // ==========================================================================
  group('SkillExecutor — map / noop / unsupported kind', () {
    // --- s20: map ---
    test(
      's20 kind=map returns resolved inputs wrapped in {value: ...}',
      () async {
        final exec = _makeExecutor();
        final def = SkillDefinition.fromYaml(
          _mapSkillYaml(actionData: {'a': 1, 'b': '{{in.name}}'}),
        );
        final result = await exec.run(def, {'name': 'Bob'});
        expect(result['value']['a'], 1);
        expect(result['value']['b'], 'Bob');
      },
    );

    // --- s21: noop ---
    test('s21 kind=noop returns empty map', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'noop_skill',
        'actionBody': {'kind': 'noop'},
      });
      final result = await exec.run(def, {});
      expect(result, isEmpty);
    });

    // --- s22: unsupported kind ---
    test('s22 unsupported kind throws StateError', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'bad_kind',
        'actionBody': {'kind': 'unknown_action_type'},
      });
      expect(() => exec.run(def, {}), throwsA(isA<StateError>()));
    });
  });

  // ==========================================================================
  // SkillExecutor — composite
  // ==========================================================================
  group('SkillExecutor — composite', () {
    // --- s23: sequences steps + captures output ---
    test(
      's23 composite sequences steps and stores output slots in ctx',
      () async {
        final exec = _makeExecutor();
        final def = SkillDefinition.fromYaml({
          'id': 'comp1',
          'actionBody': {
            'kind': 'composite',
            'steps': [
              {
                'kind': 'map',
                'output': 'first_out',
                'inputs': {'val': 'step_one'},
              },
              {
                'kind': 'map',
                'inputs': {'echo': '{{step.first_out.value.val}}'},
              },
            ],
          },
        });
        final result = await exec.run(def, {});
        expect(result['value']['echo'], 'step_one');
      },
    );

    // --- s24: all noop steps → last output is empty ---
    test('s24 composite with all noop sub-steps returns empty map', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'comp2',
        'actionBody': {
          'kind': 'composite',
          'steps': [
            {'kind': 'noop'},
            {'kind': 'noop'},
          ],
        },
      });
      final result = await exec.run(def, {});
      expect(result, isEmpty);
    });
  });

  // ==========================================================================
  // SkillExecutor — fact.save (no knowledge registry)
  // ==========================================================================
  group('SkillExecutor — fact.save (stub system, no knowledge registry)', () {
    // --- s25: fact.save calls system.facts.extractFragments ---
    test('s25 fact.save step with stub system returns saved=true', () async {
      final exec = _makeExecutor();
      // _knowledge is not attached, so it falls back to
      // system.facts.extractFragments (stub is a no-op).
      final def = SkillDefinition.fromYaml({
        'id': 'save_skill',
        'actionBody': {
          'kind': 'fact.save',
          'data': {'category': 'decisions', 'key': 'arch_choice'},
          'inputs': {'content': 'Use Flutter for mobile'},
        },
      });
      final result = await exec.run(def, {});
      expect(result['saved'], true);
      expect(result['category'], 'decisions');
      expect(result['key'], 'arch_choice');
    });
  });

  // ==========================================================================
  // SkillExecutor — adapter binding / API surface
  // ==========================================================================
  group('SkillExecutor — adapter binding', () {
    // --- s26: hasAnyLlm false initially ---
    test('s26 hasAnyLlm is false when no adapters are bound', () {
      final exec = _makeExecutor();
      expect(exec.hasAnyLlm, isFalse);
    });

    // --- s27: samplingProvider ---
    test(
      's27 samplingProvider is null initially, non-null after attachSampling',
      () {
        final exec = _makeExecutor();
        expect(exec.samplingProvider, isNull);

        Future<String> stubSampling({
          required String prompt,
          String? systemPrompt,
          double? temperature,
          int maxTokens = 2000,
        }) async => 'stub response';

        exec.attachSampling(stubSampling);
        expect(exec.samplingProvider, isNotNull);
      },
    );

    // --- s28: callHostTool throws when not bound ---
    test('s28 callHostTool throws StateError when host callTool not bound', () {
      final exec = _makeExecutor();
      expect(
        () => exec.callHostTool('browser.navigate', {}),
        throwsA(isA<StateError>()),
      );
    });

    // --- s29: callHostToolJson decodes JSON text ---
    test(
      's29 callHostToolJson decodes JSON text content from host result',
      () async {
        final exec = _makeExecutor();
        exec.bindHostCallTool(
          (name, args) async => KernelToolResult(
            content: [
              const KernelTextContent(text: '{"status":"ok","count":3}'),
            ],
          ),
        );

        final result = await exec.callHostToolJson('any.tool', {'arg': 'val'});
        expect(result['status'], 'ok');
        expect(result['count'], 3);
      },
    );

    test(
      's29b callHostToolJson returns empty map when content is empty',
      () async {
        final exec = _makeExecutor();
        exec.bindHostCallTool(
          (name, args) async => KernelToolResult(content: const []),
        );

        final result = await exec.callHostToolJson('any.tool', {});
        expect(result, isEmpty);
      },
    );

    test(
      's29c callHostToolJson wraps non-map decoded result in {result:}',
      () async {
        final exec = _makeExecutor();
        exec.bindHostCallTool(
          (name, args) async => KernelToolResult(
            content: [const KernelTextContent(text: '"scalar_value"')],
          ),
        );

        final result = await exec.callHostToolJson('any.tool', {});
        expect(result['result'], 'scalar_value');
      },
    );
  });

  // ==========================================================================
  // SKIP notes for paths requiring live host capabilities
  // ==========================================================================
  group('SKIPPED — require live host capabilities', () {
    test(
      'SKIP _runLlm requires OpsBuiltInApp (internal LLM provider or sampling)',
      () {},
      skip: 'Requires live LLM provider wired by OpsBuiltInApp.ensureBoot',
    );
    test(
      'SKIP _runBrowser requires host browser.* capability wired via bindHostCallTool',
      () {},
      skip: 'Requires live host browser capability (OpsBuiltInApp)',
    );
    test(
      'SKIP _runMcp requires host mcp.call_tool capability',
      () {},
      skip: 'Requires live host MCP capability (OpsBuiltInApp)',
    );
    test(
      'SKIP _runIngest requires host ingest.run capability',
      () {},
      skip: 'Requires live host ingest capability (OpsBuiltInApp)',
    );
    test(
      'SKIP _runChannel requires host channel.send capability',
      () {},
      skip: 'Requires live host channel capability (OpsBuiltInApp)',
    );
  });
}
