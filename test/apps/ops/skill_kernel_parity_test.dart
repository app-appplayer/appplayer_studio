/// The Ops skill engine and the kernel skill runtime must do the same thing.
///
/// Every case runs one skill definition twice — once on the Ops engine, once
/// on the kernel — against identical recording fakes (host tools, the LLM
/// answer, the knowledge registry), and asserts that the result, the order and
/// arguments of every outside call, and the kind of exception are the same.
/// The shipped skills are the corpus; the synthetic cases are the template
/// corners where the two renderers could part ways.
library;

import 'dart:convert';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart' show FactRecord, StepActionType;
import 'package:appplayer_studio/builtin_api.dart'
    show KernelTextContent, KernelToolResult, KnowledgeSystem;
import 'package:appplayer_studio/src/apps/ops/adapters/llm_adapter.dart';
import 'package:appplayer_studio/src/apps/ops/init/workspace_context.dart';
import 'package:appplayer_studio/src/apps/ops/registries/knowledge_registry.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_definition.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_executor.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_kernel_runner.dart';
import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Everything a run did to the outside, in order.
class _Trace {
  final List<String> calls = <String>[];
  Object? result;
  String? errorType;
  String? errorText;
  String? engine;
}

class _Rec extends KnowledgeRegistry {
  _Rec(
    this.trace, {
    required super.kv,
    required super.knowledgeSystem,
    required super.rootDir,
  });
  final _Trace trace;

  @override
  Future<void> saveFact({
    required String category,
    required String key,
    required Object value,
    Map<String, Object?>? metadata,
    String? workspaceId,
  }) async {
    trace.calls.add(
      'saveFact ${jsonEncode({'category': category, 'key': key, 'value': value, 'ws': workspaceId})}',
    );
  }
}

/// An executor that notes every fact listing, whichever engine asks for it.
class _RecExec extends SkillExecutor {
  _RecExec(this.trace) : super(system: KnowledgeSystem.stub());
  final _Trace trace;

  @override
  Future<Map<String, dynamic>> listFacts({
    String? workspaceId,
    Object? types,
    Object? limit,
  }) {
    trace.calls.add(
      // The workspace the listing will read: a named one, else the pinned one.
      'facts ${jsonEncode({'ws': workspaceId ?? WorkspaceExecutionContext.current, 'types': types, 'limit': limit})}',
    );
    return super.listFacts(
      workspaceId: workspaceId,
      types: types,
      limit: limit,
    );
  }
}

Object? _plain(Object? v) => jsonDecode(jsonEncode(v));

Future<_Trace> _run(
  bool kernel,
  SkillDefinition def,
  Map<String, dynamic> inputs, {
  String? actor = 'agent1',
  String? workspace = 'org/ws1',
  Map<String, dynamic> Function(String name, Map<String, dynamic> args)? host,
}) async {
  final trace = _Trace();
  final tmp = await Directory.systemTemp.createTemp('parity_');
  addTearDown(() => tmp.delete(recursive: true));
  final exec = _RecExec(trace)..useKernelEngine = kernel;
  exec.attachAdapters(
    llm: LlmAdapter.forTests(),
    knowledge: _Rec(
      trace,
      kv: KvStoragePortAdapter(
        rootDir: p.join(tmp.path, 'kv'),
        workspaceId: 'org/ws1',
      ),
      knowledgeSystem: KnowledgeSystem.stub(),
      rootDir: tmp.path,
    ),
  );
  exec.attachSampling(({
    required String prompt,
    String? systemPrompt,
    double? temperature,
    int maxTokens = 2000,
  }) async {
    trace.calls.add(
      'llm ${jsonEncode({'prompt': prompt, 'system': systemPrompt, 'temp': temperature, 'max': maxTokens})}',
    );
    // quality_appraise asks for JSON and reads it back.
    if (prompt.contains('Return a score')) {
      return '{"score": 0.5, "reason": "ok"}';
    }
    return 'answer(${prompt.length})';
  });
  exec.bindHostCallTool((name, args) async {
    trace.calls.add('host $name ${jsonEncode(args)}');
    if (name == 'knowledge_fact_list') {
      // The host tool is the executor's own listing.
      return KernelToolResult(
        content: [
          KernelTextContent(
            text: jsonEncode(
              await exec.listFacts(
                workspaceId: args['workspaceId'] as String?,
                types: args['types'],
                limit: args['limit'],
              ),
            ),
          ),
        ],
      );
    }
    final out =
        host?.call(name, args) ?? <String, dynamic>{'ok': true, 'tool': name};
    return KernelToolResult(
      content: [KernelTextContent(text: jsonEncode(out))],
    );
  });
  try {
    // `dispatch` pins the workspace around every run; so does this.
    trace.result = _plain(
      await WorkspaceExecutionContext.run(
        workspace,
        () => exec.run(def, inputs, actorId: actor, workspaceId: workspace),
      ),
    );
  } catch (e) {
    trace.errorType = e.runtimeType.toString();
    trace.errorText = '$e';
  }
  trace.engine = exec.lastEngine;
  return trace;
}

Future<void> _same(
  SkillDefinition def,
  Map<String, dynamic> inputs, {
  String? actor = 'agent1',
  String? workspace = 'org/ws1',
  Map<String, dynamic> Function(String, Map<String, dynamic>)? host,
  bool expectError = false,
}) async {
  final old = await _run(
    false,
    def,
    inputs,
    actor: actor,
    workspace: workspace,
    host: host,
  );
  final now = await _run(
    true,
    def,
    inputs,
    actor: actor,
    workspace: workspace,
    host: host,
  );
  expect(now.engine, 'kernel', reason: 'the kernel engine must have run it');
  expect(old.engine, 'ops');
  // `auto_<microseconds>` keys are the clock, not behaviour.
  List<String> calm(List<String> l) => [
    for (final c in l)
      if (!c.startsWith('host knowledge_fact_list '))
        c.replaceAll(RegExp(r'auto_\d+'), 'auto_N'),
  ];
  expect(calm(now.calls), calm(old.calls), reason: 'outside calls differ');
  expect(
    jsonEncode(now.result).replaceAll(RegExp(r'auto_\d+'), 'auto_N'),
    jsonEncode(old.result).replaceAll(RegExp(r'auto_\d+'), 'auto_N'),
    reason: 'result differs',
  );
  expect(now.errorType, old.errorType, reason: 'exception kind differs');
  expect(now.errorText, old.errorText, reason: 'exception text differs');
  if (expectError) {
    expect(old.errorType, isNotNull);
  } else {
    expect(
      old.errorType,
      isNull,
      reason: 'unexpected failure: ${old.errorText}',
    );
  }
}

SkillDefinition _def(Map<String, dynamic> y) => SkillDefinition.fromYaml(y);

Object? _yamlToPlain(Object? y) {
  if (y is YamlMap) {
    return {for (final e in y.entries) '${e.key}': _yamlToPlain(e.value)};
  }
  if (y is YamlList) return [for (final e in y) _yamlToPlain(e)];
  return y;
}

void main() {
  group('shipped skills', () {
    final dir = Directory('lib/src/apps/ops/skills/internal');
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.yaml'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    test('there are skills to compare', () => expect(files, hasLength(12)));

    for (final f in files) {
      test('${p.basename(f.path)} runs the same on both engines', () async {
        final y =
            _yamlToPlain(loadYaml(f.readAsStringSync()))
                as Map<String, dynamic>;
        final def = _def(y);
        final inputs = <String, dynamic>{
          'adId': 'ad-9',
          'action': 'approve',
          'title': 'T',
          'category': 'news',
          'body': 'B',
          'notes': 'N',
          'postId': 'p-1',
          'to': 'ko,en',
          'tags': 'x,y',
          'month': '2026-10',
          'period': 'week',
          'sections': 'a,b',
          'question': 'why?',
          'limit': '5',
          'metric': 'clarity',
          'prev': 'prior output',
          'key': 'k1',
          'value': 'v1',
        };
        await _same(
          def,
          inputs,
          host: (name, args) {
            if (name.startsWith('browser.')) {
              return {
                'text': 'page body',
                'publishedAt': '2026-10-31',
                'echo': args,
              };
            }
            return {'ok': true};
          },
        );
      });
    }
  });

  test('ad_publish reaches the browser with its url and steps', () async {
    final f = File('lib/src/apps/ops/skills/internal/ad_publish.yaml');
    final def = _def(
      _yamlToPlain(loadYaml(f.readAsStringSync())) as Map<String, dynamic>,
    );
    final inputs = {'adId': 'ad-9', 'action': 'reject'};
    for (final kernel in [false, true]) {
      final trace = await _run(kernel, def, inputs);
      expect(trace.errorType, isNull, reason: trace.errorText);
      expect(trace.calls, hasLength(1));
      final call = trace.calls.single;
      expect(call, startsWith('host browser.submit_form '));
      final args =
          jsonDecode(call.substring('host browser.submit_form '.length))
              as Map<String, dynamic>;
      expect(args['url'], 'https://makemind.dev/admin/ads/ad-9/review');
      expect(
        (args['steps'] as List).single['selector'],
        'button[data-action=reject]',
      );
      expect(args['capture_receipt'], true);
    }
  });

  group('llm steps on the kernel', () {
    String toolOf(Map<String, dynamic> step) {
      final m =
          OpsSkillConverter.convert(
            _def({
              'id': 't',
              'actionBody': {
                'kind': 'composite',
                'steps': [step],
              },
            }),
          ).module;
      final a = m.procedures.single.steps.first.action;
      return a.type == StepActionType.prompt ? 'llm' : '${a.config['tool']}';
    }

    test('a plain llm step is the kernel\'s own', () {
      expect(toolOf({'kind': 'llm', 'prompt': 'hi'}), 'llm');
      expect(
        toolOf({
          'kind': 'llm',
          'data': {'prompt': 'hi', 'temperature': 0.2, 'maxTokens': 50},
        }),
        'llm',
      );
    });

    test('values the Ops step would reject keep going through it', () {
      expect(toolOf({'kind': 'llm', 'temperature': '0.2'}), 'ops.step');
      expect(toolOf({'kind': 'llm', 'maxTokens': 5.5}), 'ops.step');
      expect(toolOf({'kind': 'llm', 'prompt': 7}), 'ops.step');
      expect(toolOf({'kind': 'llm', 'systemPrompt': 3}), 'ops.step');
      expect(
        toolOf({'kind': 'llm', 'systemPrompt': 'be {{ in.tone }}'}),
        'ops.step',
      );
    });

    test('the kernel step is told not to extract claims', () {
      final m =
          OpsSkillConverter.convert(
            _def({
              'id': 't',
              'actionBody': {
                'kind': 'llm',
                'data': {'prompt': 'p'},
              },
            }),
          ).module;
      expect(
        m.procedures.single.steps.first.action.config['extractClaims'],
        'none',
      );
      expect(m.procedures.single.steps.first.action.config['maxTokens'], 2000);
    });

    test('a model answer costs exactly one model call', () async {
      for (final kernel in [false, true]) {
        var calls = 0;
        final exec = SkillExecutor(system: KnowledgeSystem.stub())
          ..useKernelEngine = kernel;
        exec.attachSampling(({
          required String prompt,
          String? systemPrompt,
          double? temperature,
          int maxTokens = 2000,
        }) async {
          calls += 1;
          return 'The sky is blue. Water is wet. The answer is 42.';
        });
        final r = await exec.run(
          _def({
            'id': 't',
            'actionBody': {
              'kind': 'llm',
              'data': {'prompt': 'p'},
            },
          }),
          {},
        );
        expect(
          calls,
          1,
          reason: 'kernel=$kernel: claims must not call the model',
        );
        expect(r, {
          'text': 'The sky is blue. Water is wet. The answer is 42.',
          'source': 'sampling',
        });
      }
    });

    test(
      'the system prompt, temperature and token limit reach the client',
      () async {
        for (final kernel in [false, true]) {
          final seen = <Object?>[];
          final exec = SkillExecutor(system: KnowledgeSystem.stub())
            ..useKernelEngine = kernel;
          exec.attachSampling(({
            required String prompt,
            String? systemPrompt,
            double? temperature,
            int maxTokens = 2000,
          }) async {
            seen.add([prompt, systemPrompt, temperature, maxTokens]);
            return 'ok';
          });
          await exec.run(
            _def({
              'id': 't',
              'actionBody': {
                'kind': 'llm',
                'data': {
                  'prompt': 'q {{ in.n }}',
                  'systemPrompt': r'be brief ${plain} \\ end',
                  'temperature': 1,
                  'maxTokens': 33,
                },
              },
            }),
            {'n': 'N'},
          );
          expect(seen, [
            ['q N', r'be brief ${plain} \\ end', 1.0, 33],
          ]);
        }
      },
    );

    test(
      'a template that reads more than the text of an answer runs on Ops',
      () async {
        final exec = SkillExecutor(system: KnowledgeSystem.stub());
        exec.attachSampling(
          ({
            required String prompt,
            String? systemPrompt,
            double? temperature,
            int maxTokens = 2000,
          }) async => 'ok',
        );
        final r = await exec.run(
          _def({
            'id': 't',
            'actionBody': {
              'kind': 'composite',
              'steps': [
                {'kind': 'llm', 'output': 'a', 'prompt': 'p'},
                {
                  'kind': 'map',
                  'inputs': {
                    'src': '{{ step.a.source }}',
                    'txt': '{{ step.a.text }}',
                  },
                },
              ],
            },
          }),
          {},
        );
        expect(exec.lastEngine, 'ops');
        expect(r['value'], {'src': 'sampling', 'txt': 'ok'});
      },
    );

    test('no model available fails the step like it always did', () async {
      for (final kernel in [false, true]) {
        final exec = SkillExecutor(system: KnowledgeSystem.stub())
          ..useKernelEngine = kernel;
        await expectLater(
          exec.run(
            _def({
              'id': 't',
              'actionBody': {
                'kind': 'llm',
                'data': {'prompt': 'p'},
              },
            }),
            {},
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('No LLM available'),
            ),
          ),
          reason: 'kernel=$kernel',
        );
      }
    });
  });

  group('fact.query on the kernel', () {
    Future<KnowledgeSystem> withFacts() async {
      final system = KnowledgeSystem.stub();
      await system.facts.writeFacts(<FactRecord>[
        FactRecord(
          id: 'a1',
          workspaceId: 'org/ws1',
          type: 'note',
          content: <String, dynamic>{
            'text': 'one',
            'n': 1,
            'f': 2.5,
            'nested': {
              'k': [1, 'two', null],
            },
          },
          createdAt: DateTime(2026),
        ),
        FactRecord(
          id: 'a2',
          workspaceId: 'org/ws1',
          type: 'event',
          content: <String, dynamic>{'text': 'two'},
          createdAt: DateTime(2026),
        ),
        FactRecord(
          id: 'b1',
          workspaceId: 'org/other',
          type: 'note',
          content: <String, dynamic>{'text': 'elsewhere'},
          createdAt: DateTime(2026),
        ),
      ]);
      return system;
    }

    Future<Object?> answer(
      bool kernel,
      Map<String, dynamic> body, {
      String? workspace = 'org/ws1',
      Map<String, dynamic> inputs = const {},
    }) async {
      final exec = SkillExecutor(system: await withFacts())
        ..useKernelEngine = kernel;
      exec.bindHostCallTool((name, args) async {
        expect(name, 'knowledge_fact_list');
        return KernelToolResult(
          content: [
            KernelTextContent(
              text: jsonEncode(
                await exec.listFacts(
                  workspaceId: args['workspaceId'] as String?,
                  types: args['types'],
                  limit: args['limit'],
                ),
              ),
            ),
          ],
        );
      });
      final r = await WorkspaceExecutionContext.run(
        workspace,
        () => exec.run(
          _def({'id': 't', 'actionBody': body}),
          inputs,
          workspaceId: workspace,
        ),
      );
      expect(exec.lastEngine, kernel ? 'kernel' : 'ops');
      return jsonEncode(r);
    }

    test('the facts come back as {count, facts:[{id,type,content}]}', () async {
      final r =
          jsonDecode((await answer(true, {'kind': 'fact.query'})) as String)
              as Map;
      expect(r['count'], 2);
      final facts = (r['facts'] as List).cast<Map>();
      expect(facts.map((f) => f['id']).toSet(), {'a1', 'a2'});
      expect(
        facts.every(
          (f) =>
              f.keys.toSet().containsAll(['id', 'type', 'content']) &&
              f.length == 3,
        ),
        isTrue,
      );
    });

    test(
      'same answer on both engines: types, limit and a named workspace',
      () async {
        final cases = <(Map<String, dynamic>, Map<String, dynamic>)>[
          ({'kind': 'fact.query'}, {}),
          (
            {
              'kind': 'fact.query',
              'inputs': {
                'types': ['note'],
              },
            },
            {},
          ),
          (
            {
              'kind': 'fact.query',
              'inputs': {'limit': 1},
            },
            {},
          ),
          (
            {
              'kind': 'fact.query',
              'inputs': {'limit': '{{ in.n }}'},
            },
            {'n': '1'},
          ),
          (
            {
              'kind': 'fact.query',
              'inputs': {'limit': 'x'},
            },
            {},
          ),
          (
            {
              'kind': 'fact.query',
              'inputs': {'workspaceId': 'org/other'},
            },
            {},
          ),
          (
            {
              'kind': 'fact.query',
              'data': {'workspaceId': 'org/other'},
            },
            {},
          ),
          (
            {
              'kind': 'fact.query',
              'inputs': {'workspaceId': '{{ in.w }}'},
            },
            {'w': 'org/other'},
          ),
          (
            {
              'kind': 'fact.query',
              'inputs': {
                'types': ['{{ in.t }}'],
              },
            },
            {'t': 'event'},
          ),
        ];
        for (final c in cases) {
          expect(
            await answer(true, c.$1, inputs: c.$2),
            await answer(false, c.$1, inputs: c.$2),
            reason: '${c.$1} ${c.$2}',
          );
        }
      },
    );

    test('without a workspace for the run, the Ops step reads it', () async {
      final def = _def({
        'id': 't',
        'actionBody': {'kind': 'fact.query'},
      });
      final step =
          OpsSkillConverter.convert(def).module.procedures.single.steps.first;
      expect(step.action.config['tool'], 'ops.step');
      final withWs =
          OpsSkillConverter.convert(
            def,
            workspaceId: 'org/ws1',
          ).module.procedures.single.steps.first;
      expect(withWs.action.config['tool'], 'knowledge_fact_list');
      final exec = SkillExecutor(system: await withFacts());
      final r = await exec.run(def, {});
      expect(r['count'], isA<int>());
    });

    test('a refused listing fails the step', () async {
      final exec = SkillExecutor(system: await withFacts());
      exec.bindHostCallTool(
        (name, args) async => KernelToolResult(
          content: [const KernelTextContent(text: 'no')],
          isError: true,
        ),
      );
      await expectLater(
        WorkspaceExecutionContext.run(
          'org/ws1',
          () => exec.run(
            _def({
              'id': 't',
              'actionBody': {'kind': 'fact.query'},
            }),
            {},
            workspaceId: 'org/ws1',
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('with no host bound the listing is read directly', () async {
      final exec = SkillExecutor(system: await withFacts());
      final r = await WorkspaceExecutionContext.run(
        'org/ws1',
        () => exec.run(
          _def({
            'id': 't',
            'actionBody': {'kind': 'fact.query'},
          }),
          {},
          workspaceId: 'org/ws1',
        ),
      );
      expect(exec.lastEngine, 'kernel');
      expect(r['count'], 2);
    });
  });

  group('browser answers that are not a map', () {
    for (final answer in ['[1,2]', '"text"', '', 'null', '7']) {
      test('host says <$answer>', () async {
        final results = <Object?>[];
        for (final kernel in [false, true]) {
          final exec = SkillExecutor(system: KnowledgeSystem.stub())
            ..useKernelEngine = kernel;
          exec.bindHostCallTool(
            (name, args) async => KernelToolResult(
              content:
                  answer.isEmpty ? const [] : [KernelTextContent(text: answer)],
            ),
          );
          results.add(
            jsonEncode(
              await exec.run(
                _def({
                  'id': 't',
                  'actionBody': {
                    'kind': 'browser',
                    'data': {'operation': 'x'},
                  },
                }),
                {},
              ),
            ),
          );
          expect(exec.lastEngine, kernel ? 'kernel' : 'ops');
        }
        expect(results[1], results[0]);
        // The decoder itself, not just the two engines agreeing.
        expect(
          results[0],
          answer == '[1,2]'
              ? '{"result":[1,2]}'
              : answer == '"text"'
              ? '{"result":"text"}'
              : answer == '7'
              ? '{"result":7}'
              : '{"result":null}',
        );
      });
    }
  });

  group('fact.save goes through the host tool', () {
    final def = _def({
      'id': 't',
      'actionBody': {
        'kind': 'fact.save',
        'data': {'category': 'c1', 'key': 'k1'},
        'inputs': {'content': 'body {{ in.n }}'},
      },
    });

    test(
      'knowledge_fact_save gets category, key and text; result keeps its shape',
      () async {
        for (final kernel in [false, true]) {
          final trace = await _run(kernel, def, {'n': 5});
          expect(trace.errorType, isNull);
          expect(trace.calls, [
            'host knowledge_fact_save {"category":"c1","key":"k1","value":"body 5"}',
          ]);
          expect(trace.result, {'saved': true, 'category': 'c1', 'key': 'k1'});
        }
      },
    );

    test('a refused save fails the step', () async {
      for (final kernel in [false, true]) {
        final exec = SkillExecutor(system: KnowledgeSystem.stub())
          ..useKernelEngine = kernel;
        exec.bindHostCallTool(
          (name, args) async => KernelToolResult(
            content: [const KernelTextContent(text: 'no workspace')],
            isError: true,
          ),
        );
        await expectLater(
          exec.run(def, {'n': 1}),
          throwsA(isA<StateError>()),
          reason: 'kernel=$kernel',
        );
      }
    });

    test('without a host endpoint the registry is used directly', () async {
      final exec = SkillExecutor(system: KnowledgeSystem.stub());
      final r = await exec.run(def, {'n': 1});
      expect(r['saved'], true);
    });
  });

  group('quality_appraise answers {score, reason}', () {
    SkillDefinition appraise() => _def(
      _yamlToPlain(
            loadYaml(
              File(
                'lib/src/apps/ops/skills/internal/quality_appraise.yaml',
              ).readAsStringSync(),
            ),
          )
          as Map<String, dynamic>,
    );

    Future<Map<String, dynamic>> answerWith(String modelText) async {
      final exec = SkillExecutor(system: KnowledgeSystem.stub());
      exec.attachSampling(
        ({
          required String prompt,
          String? systemPrompt,
          double? temperature,
          int maxTokens = 2000,
        }) async => modelText,
      );
      return exec.run(appraise(), {'metric': 'clarity', 'prev': 'text'});
    }

    test('plain JSON', () async {
      expect(await answerWith('{"score": 0.8, "reason": "clear"}'), {
        'score': 0.8,
        'reason': 'clear',
      });
    });

    test('JSON inside a code fence', () async {
      expect(
        await answerWith('```json\n{"score": 0.4, "reason": "vague"}\n```'),
        {'score': 0.4, 'reason': 'vague'},
      );
    });

    test(
      'an answer that is not JSON fails the skill as a runtime error',
      () async {
        await expectLater(
          answerWith('I would say pretty good'),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('both engines give the same answer', () async {
      for (final text in ['{"score":1,"reason":"r"}', 'not json']) {
        final results = <Object?>[];
        for (final kernel in [false, true]) {
          final exec = SkillExecutor(system: KnowledgeSystem.stub())
            ..useKernelEngine = kernel;
          exec.attachSampling(
            ({
              required String prompt,
              String? systemPrompt,
              double? temperature,
              int maxTokens = 2000,
            }) async => text,
          );
          try {
            results.add(
              await exec.run(appraise(), {'metric': 'm', 'prev': 'p'}),
            );
          } catch (e) {
            results.add('${e.runtimeType}: $e');
          }
        }
        expect(results[1], results[0], reason: text);
      }
    });
  });

  group('the repository\'s real skill definitions', () {
    // Every skill definition the repository holds outside the shipped set:
    // the `ops/` projects, the studio's test workspaces and the older Ops
    // tool's workspaces.
    final roots = <String>[
      '../../../../ops',
      '../../../workspace',
      '../../../../os/tools/ops/workspaces',
    ];
    final files = <File>[
      for (final r in roots)
        if (Directory(r).existsSync())
          ...Directory(r)
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (f) =>
                    f.path.endsWith('.yaml') &&
                    f.path.contains('/skills/') &&
                    !f.path.contains('/.history/'),
              ),
    ]..sort((a, b) => a.path.compareTo(b.path));

    test(
      'they are found',
      () {
        expect(files, isNotEmpty);
      },
      skip: files.isEmpty ? 'the repository skills are not on disk' : null,
    );

    test(
      'every one runs the same on both engines',
      () async {
        final differing = <String>[];
        var ran = 0;
        var executable = 0;
        for (final f in files) {
          final Object? y;
          try {
            y = _yamlToPlain(loadYaml(f.readAsStringSync()));
          } catch (_) {
            continue;
          }
          if (y is! Map<String, dynamic> || y['id'] == null) continue;
          final SkillDefinition def;
          try {
            def = _def(y);
          } catch (_) {
            continue;
          }
          final inputs = <String, dynamic>{};
          final props =
              (y['inputSchema'] is Map)
                  ? ((y['inputSchema'] as Map)['properties'] as Map?)
                  : null;
          for (final k in (props ?? const {}).keys) {
            inputs['$k'] = 'v_$k';
          }
          try {
            final old = await _run(false, def, inputs);
            final now = await _run(true, def, inputs);
            ran += 1;
            if (y['actionBody'] != null || y['action'] != null) {
              executable += 1;
            }
            String norm(_Trace t) => jsonEncode([
              t.calls
                  .where((c) => !c.startsWith('host knowledge_fact_list '))
                  .map((c) => c.replaceAll(RegExp(r'auto_\d+'), 'auto_N'))
                  .toList(),
              t.result,
              t.errorType,
              t.errorText,
            ]).replaceAll(RegExp(r'auto_\d+'), 'auto_N');
            if (norm(old) != norm(now)) differing.add(f.path);
          } catch (e) {
            differing.add('${f.path} ($e)');
          }
        }
        // ignore: avoid_print
        print(
          'REALSKILLS ran=$ran of ${files.length} executable=$executable '
          'differing=${differing.length}',
        );
        expect(differing, isEmpty);
      },
      skip: files.isEmpty ? 'the repository skills are not on disk' : null,
    );
  });

  group('template corners', () {
    test('missing, nested and non-string values', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'composite',
            'steps': [
              {
                'kind': 'map',
                'output': 'a',
                'inputs': {
                  'n': '{{ in.n }}',
                  'missing': '{{ in.nope }}',
                  'deep': '{{ in.obj.x.y }}',
                  'list': '{{ in.list }}',
                  'obj': '{{ in.obj }}',
                  'mixed': 'a {{ in.n }} b {{ in.obj.x }} c',
                  'plain': 5,
                  'flag': true,
                },
              },
              {
                'kind': 'map',
                'output': 'b',
                'inputs': {
                  'prev': '{{ step.a.value }}',
                  'only': '{{ step.a.value.n }}',
                },
              },
            ],
          },
        }),
        {
          'n': 7,
          'list': [
            1,
            'two',
            {'three': 3},
          ],
          'obj': {
            'x': {'y': 'deep'},
          },
        },
      );
    });

    test('keys that are not identifiers or are reserved words', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'map',
            'inputs': {
              'h': '{{ in.a-b }}',
              'k': '{{ in.class }}',
              't': '{{ in.true }}',
              's': '{{ in.a b }}',
              'q': '{{ in.say"hi" }}',
            },
          },
        }),
        {
          'a-b': 'dash',
          'class': 'c',
          'true': 'T',
          'a b': 'space',
          'say"hi"': 'quote',
        },
      );
    });

    test('dollar signs, braces and backslashes in plain text', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'map',
            'inputs': {
              'a': r'cost ${price} and \$5 and \\ and $ alone',
              'b': 'json { "a": 1 } and {{ in.n }}',
              'c':
                  r'${'
                  r'{{ in.n }}'
                  r'}',
            },
          },
        }),
        {'n': 3},
      );
    });

    test('a path that runs into a list, a string or a number', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'map',
            'inputs': {
              'idx': '{{ in.items.0 }}',
              'named': '{{ in.items.first }}',
              'len': '{{ in.items.length }}',
              'strlen': '{{ in.name.length }}',
              'strpart': '{{ in.name.first }}',
              'num': '{{ in.n.x }}',
              'deep': '{{ in.obj.list.1 }}',
              'ok': '{{ in.obj.k }}',
              'nested_null': '{{ in.nothing.x }}',
            },
          },
        }),
        {
          'items': ['a', 'b'],
          'name': 'hello',
          'n': 5,
          'obj': {
            'list': ['p', 'q'],
            'k': 'v',
          },
          'nothing': null,
        },
      );
    });

    test('odd characters in keys', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'map',
            'inputs': {
              'q': '{{ in.a"b }}',
              'bs': r'{{ in.a\b }}',
              'u': '{{ in.키 }}',
              'sp': '{{ in.x y.z w }}',
            },
          },
        }),
        {
          'a"b': 1,
          r'a\b': 2,
          '키': 3,
          'x y': {'z w': 4},
        },
      );
    });

    test('a backslash right before a template', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'map',
            'inputs': {
              'a': r'dir\{{ in.x }}',
              'b': r'two\\{{ in.x }}',
              'c': r'{{ in.x }}\',
              'd': r'\{{ in.x }}\{{ in.x }}',
              'e': r'\$ {{ in.x }}',
            },
          },
        }),
        {'x': 'X'},
      );
    });

    test('values that are not text or numbers', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'map',
            'inputs': {
              'nothing': null,
              'flag': false,
              'big': 1234567890123456789,
              'ratio': 0.1,
              'rows': [
                {'k': '{{ in.x }}', 'n': 1},
                [1, 2, '{{ in.x }}'],
              ],
            },
          },
        }),
        {'x': 'X'},
      );
    });

    test(
      'a step kind that looks like a template is still just a kind',
      () async {
        await _same(
          _def({
            'id': 't',
            'actionBody': {'kind': r'${x}'},
          }),
          {},
          expectError: true,
        );
        await _same(
          _def({
            'id': 't',
            'actionBody': {'kind': '{{ in.k }}'},
          }),
          {'k': 'map'},
          expectError: true,
        );
      },
    );

    test('actor and workspace', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'map',
            'inputs': {
              'a': '{{ actor }}',
              'w': '{{ workspace }}',
              'x': '{{ actor.id }}',
            },
          },
        }),
        {},
      );
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'map',
            'inputs': {'a': '{{ actor }}'},
          },
        }),
        {},
        actor: null,
        workspace: null,
      );
    });

    test(
      'a step cannot read its own output; a later duplicate output wins',
      () async {
        await _same(
          _def({
            'id': 't',
            'actionBody': {
              'kind': 'composite',
              'steps': [
                {
                  'kind': 'map',
                  'output': 'a',
                  'inputs': {'v': 'first'},
                },
                {
                  'kind': 'map',
                  'output': 'a',
                  'inputs': {'v': '{{ step.a.value.v }}-self'},
                },
                {
                  'kind': 'map',
                  'output': 'b',
                  'inputs': {
                    'v': '{{ step.a.value.v }}',
                    'nope': '{{ step.zzz.value }}',
                  },
                },
              ],
            },
          }),
          {},
        );
      },
    );

    test('a step without output or id', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'composite',
            'steps': [
              {
                'kind': 'map',
                'inputs': {'v': 1},
              },
              {
                'kind': 'map',
                'inputs': {'v': '{{ step.a }}'},
              },
            ],
          },
        }),
        {},
      );
    });

    test('shorthand step keys become data', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'composite',
            'steps': [
              {
                'kind': 'llm',
                'prompt': 'hello {{ in.n }}',
                'maxTokens': 11,
                'temperature': 0.5,
                'systemPrompt': 'sys',
              },
            ],
          },
        }),
        {'n': 'world'},
      );
    });
  });

  group('step kinds and bodies', () {
    test('every kind through one composite', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'composite',
            'steps': [
              {
                'kind': 'browser',
                'output': 'b',
                'operation': 'page_view',
                'inputs': {'url': 'u/{{ in.id }}'},
              },
              {
                'kind': 'mcp',
                'output': 'm',
                'data': {'server': 's1', 'tool': 'tt'},
                'inputs': {'q': '{{ step.b.text }}'},
              },
              {
                'kind': 'channel',
                'output': 'c',
                'inputs': {
                  'kind': 'info',
                  'title': 'T',
                  'body': '{{ step.m.content }}',
                  'notificationId': 'n1',
                },
              },
              {
                'kind': 'fact.query',
                'output': 'f',
                'inputs': {'workspaceId': 'org/x', 'limit': '3'},
              },
              {
                'kind': 'llm',
                'output': 'l',
                'prompt': 'P {{ step.f.facts }} {{ step.c.status }}',
              },
              {
                'kind': 'fact.save',
                'category': 'cat',
                'key': 'kk',
                'inputs': {'content': '{{ step.l.text }}'},
              },
            ],
          },
        }),
        {'id': 'z'},
      );
    });

    test('a single-step body', () async {
      for (final kind in ['llm', 'fact.save', 'browser', 'map', 'noop']) {
        await _same(
          _def({
            'id': 't',
            'actionBody': {
              'kind': kind,
              'data': {
                'prompt': 'x {{ in.n }}',
                'operation': 'op',
                'category': 'c',
                'key': 'k',
              },
              'inputs': {'content': '{{ in.n }}'},
            },
          }),
          {'n': 'v'},
        );
      }
    });

    test('no steps, no body', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {'kind': 'composite', 'steps': []},
        }),
        {},
      );
      await _same(_def({'id': 't'}), {});
    });
  });

  group('failures keep their kind', () {
    test('a step that throws ArgumentError', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {'kind': 'browser', 'data': {}},
        }),
        {},
        expectError: true,
      );
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'mcp',
            'data': {'server': 's'},
          },
        }),
        {},
        expectError: true,
      );
    });

    test('an unsupported kind', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {'kind': 'form'},
        }),
        {},
        expectError: true,
      );
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'composite',
            'steps': [
              {
                'kind': 'map',
                'inputs': {'a': 1},
              },
              {'kind': 'scripted'},
              {
                'kind': 'map',
                'inputs': {'never': 1},
              },
            ],
          },
        }),
        {},
        expectError: true,
      );
    });

    test('a nested composite', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {
            'kind': 'composite',
            'steps': [
              {
                'kind': 'composite',
                'steps': [
                  {'kind': 'noop'},
                ],
              },
            ],
          },
        }),
        {},
        expectError: true,
      );
    });

    test('a host tool that throws', () async {
      await _same(
        _def({
          'id': 't',
          'actionBody': {'kind': 'browser', 'operation': 'x'},
        }),
        {},
        host: (name, args) => throw StateError('host down'),
        expectError: true,
      );
    });
  });

  group('which steps the kernel runs itself', () {
    String toolOf(Map<String, dynamic> body, int index) {
      final module =
          OpsSkillConverter.convert(
            _def({'id': 't', 'actionBody': body}),
          ).module;
      final step = module.procedures.single.steps[index];
      return step.action.type == StepActionType.prompt
          ? 'llm'
          : '${step.action.config['tool']}';
    }

    test('a browser step with a plain operation calls the host browser', () {
      expect(
        toolOf({
          'kind': 'browser',
          'data': {'operation': 'page_view'},
        }, 0),
        'browser.page_view',
      );
      expect(
        toolOf({
          'kind': 'composite',
          'steps': [
            {
              'kind': 'browser',
              'operation': 'extract',
              'inputs': {'url': 'u'},
            },
          ],
        }, 0),
        'browser.extract',
      );
    });

    test(
      'a browser step that names no plain operation stays on the Ops step',
      () {
        expect(toolOf({'kind': 'browser', 'data': {}}, 0), 'ops.step');
        expect(
          toolOf({
            'kind': 'browser',
            'data': {'operation': '{{ in.op }}'},
          }, 0),
          'ops.step',
        );
      },
    );

    test('every other kind stays on the Ops step', () {
      for (final kind in [
        'fact.save',
        'mcp',
        'channel',
        'ingest',
        'map',
        'parse_json',
      ]) {
        expect(toolOf({'kind': kind}, 0), 'ops.step', reason: kind);
      }
    });
  });

  group('what must not leak between runs', () {
    SkillExecutor make(bool kernel, void Function(String) onHost) {
      final exec = SkillExecutor(system: KnowledgeSystem.stub())
        ..useKernelEngine = kernel;
      exec.bindHostCallTool((name, args) async {
        onHost('$name pinned=${WorkspaceExecutionContext.current}');
        return KernelToolResult(
          content: [
            KernelTextContent(text: jsonEncode({'who': args['tag']})),
          ],
        );
      });
      return exec;
    }

    final def = _def({
      'id': 't',
      'actionBody': {
        'kind': 'composite',
        'steps': [
          {
            'kind': 'browser',
            'output': 'a',
            'operation': 'one',
            'inputs': {'tag': '{{ in.tag }}'},
          },
          {
            'kind': 'browser',
            'output': 'b',
            'operation': 'two',
            'inputs': {'tag': '{{ step.a.who }}'},
          },
        ],
      },
    });

    test('the pinned workspace is still pinned inside every step', () async {
      final seen = <bool, List<String>>{false: [], true: []};
      for (final kernel in [false, true]) {
        final exec = make(kernel, seen[kernel]!.add);
        await WorkspaceExecutionContext.run(
          'org/pinned',
          () => exec.run(def, {'tag': 'x'}, workspaceId: 'org/pinned'),
        );
      }
      expect(seen[true], seen[false]);
      expect(seen[true], everyElement(contains('pinned=org/pinned')));
      expect(seen[true], hasLength(2));
    });

    test('two runs at once do not see each other', () async {
      final exec = make(true, (_) {});
      final results = await Future.wait([
        for (final tag in ['A', 'B', 'C', 'D']) exec.run(def, {'tag': tag}),
      ]);
      expect([for (final r in results) (r['who'])], ['A', 'B', 'C', 'D']);
    });

    test('the caller\'s inputs are not touched', () async {
      final exec = make(true, (_) {});
      final inputs = <String, dynamic>{
        'tag': 't',
        'nested': {
          'k': [1, 2],
        },
      };
      final before = jsonEncode(inputs);
      await exec.run(def, inputs);
      expect(jsonEncode(inputs), before);
    });

    test(
      'a skill the converter cannot express runs on the Ops engine',
      () async {
        final exec = make(true, (_) {});
        final whole = _def({
          'id': 't',
          'actionBody': {
            'kind': 'map',
            'inputs': {'all': '{{ in }}'},
          },
        });
        final r = await exec.run(whole, {'a': 1});
        expect(exec.lastEngine, 'ops');
        expect(r['value'], isA<Map>());
      },
    );
  });
}
