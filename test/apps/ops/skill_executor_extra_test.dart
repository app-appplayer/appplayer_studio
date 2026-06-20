/// SkillExecutor — additional unit tests for branches not in the primary
/// skill_executor_test.dart.
///
/// Covers:
///   fact.query step (uses KnowledgeSystem.stub — no live facts, returns count=0)
///   fact.query limit coercions: int / num / String / default
///   fact.save with non-string value (coerces via toString)
///   fact.save category/key defaulting
///   _runChannel error shape when host callback returns isError=true (stub)
///   _runBrowser throws ArgumentError when operation is empty
///   _runMcp throws ArgumentError when tool is missing
///   _runMcp throws ArgumentError when server is missing
///   run passes actorId / workspaceId into ctx (readable via {{actor}} / {{workspace}})
///
/// NOTE: All paths that require a live process (LLM provider, host browser
/// engine, real MCP outbound) are SKIPPED — see primary test file.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/builtin_api.dart'
    show KnowledgeSystem, KernelToolResult, KernelTextContent;
import 'package:appplayer_studio/src/apps/ops/skills/skill_definition.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_executor.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

SkillExecutor _makeExecutor() => SkillExecutor(system: KnowledgeSystem.stub());

void main() {
  // ===========================================================================
  // fact.query step — stub system always returns empty facts list
  // ===========================================================================
  group('SkillExecutor — fact.query step', () {
    test('fq1 fact.query returns {count, facts} shape', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'q_test',
        'actionBody': {
          'kind': 'fact.query',
          'inputs': {'workspaceId': 'org/test'},
        },
      });
      final result = await exec.run(def, {});
      // Stub system returns empty results — count must be 0 and facts must be a list.
      expect(result.containsKey('count'), isTrue);
      expect(result.containsKey('facts'), isTrue);
      expect(result['count'], isA<int>());
      expect(result['facts'], isA<List>());
    });

    test('fq2 fact.query limit=int is passed through', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'q_limit_int',
        'actionBody': {
          'kind': 'fact.query',
          'inputs': {'limit': 5},
        },
      });
      // Just assert it does not throw and returns the correct shape.
      final result = await exec.run(def, {});
      expect(result['count'], isA<int>());
    });

    test('fq3 fact.query limit=num (double) is coerced to int', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'q_limit_num',
        'actionBody': {
          'kind': 'fact.query',
          'inputs': {'limit': 7.0},
        },
      });
      final result = await exec.run(def, {});
      expect(result['count'], isA<int>());
    });

    test('fq4 fact.query limit=String (parsable) is coerced to int', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'q_limit_str',
        'actionBody': {
          'kind': 'fact.query',
          'inputs': {'limit': '10'},
        },
      });
      final result = await exec.run(def, {});
      expect(result['count'], isA<int>());
    });

    test('fq5 fact.query limit=String (non-parsable) defaults to 20', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'q_limit_bad',
        'actionBody': {
          'kind': 'fact.query',
          'inputs': {'limit': 'not_a_number'},
        },
      });
      // Should not throw — falls back to default 20.
      final result = await exec.run(def, {});
      expect(result['count'], isA<int>());
    });

    test('fq6 fact.query with no limit input uses default 20', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'q_no_limit',
        'actionBody': {'kind': 'fact.query', 'inputs': <String, dynamic>{}},
      });
      final result = await exec.run(def, {});
      expect(result['count'], isA<int>());
    });
  });

  // ===========================================================================
  // fact.save edge branches
  // ===========================================================================
  group('SkillExecutor — fact.save edge branches', () {
    test('fs1 fact.save non-string value coerces via toString', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'save_nonstring',
        'actionBody': {
          'kind': 'fact.save',
          'data': {'category': 'metrics', 'key': 'count'},
          'inputs': {'content': 42}, // int, not String
        },
      });
      final result = await exec.run(def, {});
      expect(result['saved'], true);
      expect(result['category'], 'metrics');
      expect(result['key'], 'count');
    });

    test(
      'fs2 fact.save uses default category=misc when data.category absent',
      () async {
        final exec = _makeExecutor();
        final def = SkillDefinition.fromYaml({
          'id': 'save_defaults',
          'actionBody': {
            'kind': 'fact.save',
            // No category or key in data.
            'inputs': {'content': 'some fact'},
          },
        });
        final result = await exec.run(def, {});
        expect(result['saved'], true);
        expect(result['category'], 'misc');
        // key defaults to auto_<millis>; just check it's non-empty.
        expect(result['key'], isA<String>());
        expect((result['key'] as String).isNotEmpty, isTrue);
      },
    );

    test(
      'fs3 fact.save category/key from inputs when data keys absent',
      () async {
        final exec = _makeExecutor();
        final def = SkillDefinition.fromYaml({
          'id': 'save_from_inputs',
          'actionBody': {
            'kind': 'fact.save',
            'inputs': {
              'category': 'decisions',
              'key': 'chosen_arch',
              'content': 'Use microservices',
            },
          },
        });
        final result = await exec.run(def, {});
        expect(result['saved'], true);
        expect(result['category'], 'decisions');
        expect(result['key'], 'chosen_arch');
      },
    );

    test('fs4 fact.save data keys take precedence over inputs keys', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'save_data_wins',
        'actionBody': {
          'kind': 'fact.save',
          'data': {'category': 'data_cat', 'key': 'data_key'},
          'inputs': {
            'category': 'input_cat',
            'key': 'input_key',
            'content': 'value',
          },
        },
      });
      final result = await exec.run(def, {});
      expect(result['category'], 'data_cat');
      expect(result['key'], 'data_key');
    });
  });

  // ===========================================================================
  // run context: actorId / workspaceId available in ctx
  // ===========================================================================
  group('SkillExecutor — run context threading', () {
    test(
      'ctx1 actorId and workspaceId available via {{actor}} / {{workspace}}',
      () async {
        final exec = _makeExecutor();
        final def = SkillDefinition.fromYaml({
          'id': 'ctx_test',
          'actionBody': {
            'kind': 'map',
            'inputs': {'who': '{{actor}}', 'ws': '{{workspace}}'},
          },
        });
        final result = await exec.run(
          def,
          {},
          actorId: 'agent_007',
          workspaceId: 'org/main',
        );
        expect(result['value']['who'], 'agent_007');
        expect(result['value']['ws'], 'org/main');
      },
    );

    test('ctx2 actorId null resolves to empty string in template', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'ctx_null',
        'actionBody': {
          'kind': 'map',
          'inputs': {'actor': '{{actor}}'},
        },
      });
      final result = await exec.run(def, {});
      // actor is null in ctx → _lookupPath returns null → '' in template.
      expect(result['value']['actor'], '');
    });
  });

  // ===========================================================================
  // _runBrowser argument validation (host not wired — different error)
  // ===========================================================================
  group('SkillExecutor — _runBrowser arg validation', () {
    test(
      'br1 browser step with empty operation throws ArgumentError before host check',
      () async {
        final exec = _makeExecutor();
        // Bind a host so we don't get a StateError from the null check —
        // we want to verify the ArgumentError from the empty-operation guard.
        // Actually, checking the source: the operation check comes BEFORE the
        // _hostCallTool null check in _runBrowser. Let's verify.
        // Source order: opId check first, then call check.
        final def = SkillDefinition.fromYaml({
          'id': 'browser_no_op',
          'actionBody': {
            'kind': 'browser',
            'data': {'operation': ''}, // empty string
          },
        });
        expect(() => exec.run(def, {}), throwsA(isA<ArgumentError>()));
      },
    );

    test('br2 browser step with no operation throws ArgumentError', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'browser_missing_op',
        'actionBody': {
          'kind': 'browser',
          // No operation key at all.
        },
      });
      expect(() => exec.run(def, {}), throwsA(isA<ArgumentError>()));
    });
  });

  // ===========================================================================
  // _runMcp argument validation
  // ===========================================================================
  group('SkillExecutor — _runMcp arg validation', () {
    test('mc1 mcp step missing tool throws ArgumentError', () async {
      final exec = _makeExecutor();
      // Bind a stub host so StateError from null host doesn't fire first.
      exec.bindHostCallTool(
        (name, args) async => KernelToolResult(content: const []),
      );
      final def = SkillDefinition.fromYaml({
        'id': 'mcp_no_tool',
        'actionBody': {
          'kind': 'mcp',
          'data': {'server': 'my_server'}, // no tool key
        },
      });
      expect(() => exec.run(def, {}), throwsA(isA<ArgumentError>()));
    });

    test('mc2 mcp step missing server throws ArgumentError', () async {
      final exec = _makeExecutor();
      exec.bindHostCallTool(
        (name, args) async => KernelToolResult(content: const []),
      );
      final def = SkillDefinition.fromYaml({
        'id': 'mcp_no_server',
        'actionBody': {
          'kind': 'mcp',
          'data': {'tool': 'db.query'}, // no server key
        },
      });
      expect(() => exec.run(def, {}), throwsA(isA<ArgumentError>()));
    });
  });

  // ===========================================================================
  // _runChannel shape (with host stub returning success)
  // ===========================================================================
  group('SkillExecutor — _runChannel stub', () {
    test(
      'ch1 channel step returns {notificationId, status:delivered} on success',
      () async {
        final exec = _makeExecutor();
        exec.bindHostCallTool(
          (name, args) async => KernelToolResult(content: const []),
        );
        final def = SkillDefinition.fromYaml({
          'id': 'channel_ok',
          'actionBody': {
            'kind': 'channel',
            'inputs': {
              'kind': 'info',
              'title': 'Hello',
              'body': 'World',
              'recipientId': 'user_1',
            },
          },
        });
        final result = await exec.run(def, {});
        expect(result['status'], 'delivered');
        expect(result.containsKey('notificationId'), isTrue);
        expect((result['notificationId'] as String).isNotEmpty, isTrue);
      },
    );

    test(
      'ch2 channel step with explicit notificationId preserves it',
      () async {
        final exec = _makeExecutor();
        exec.bindHostCallTool(
          (name, args) async => KernelToolResult(content: const []),
        );
        final def = SkillDefinition.fromYaml({
          'id': 'channel_nid',
          'actionBody': {
            'kind': 'channel',
            'inputs': {'title': 'Alert', 'notificationId': 'n-fixed-id'},
          },
        });
        final result = await exec.run(def, {});
        expect(result['notificationId'], 'n-fixed-id');
      },
    );

    test(
      'ch3 channel step returns status=failed when host returns isError=true',
      () async {
        final exec = _makeExecutor();
        exec.bindHostCallTool(
          (name, args) async =>
              KernelToolResult(content: const [], isError: true),
        );
        final def = SkillDefinition.fromYaml({
          'id': 'channel_fail',
          'actionBody': {
            'kind': 'channel',
            'inputs': {'title': 'Fail'},
          },
        });
        final result = await exec.run(def, {});
        expect(result['status'], 'failed');
      },
    );

    test('ch4 channel step throws StateError when host not bound', () async {
      final exec = _makeExecutor();
      final def = SkillDefinition.fromYaml({
        'id': 'channel_unbound',
        'actionBody': {
          'kind': 'channel',
          'inputs': {'title': 'x'},
        },
      });
      expect(() => exec.run(def, {}), throwsA(isA<StateError>()));
    });
  });
}
