/// The call contract of every built-in tool, measured the way an external
/// LLM meets it: through the host registry, by name, with JSON arguments.
///
/// For each surface (App Builder · Ops · Form Builder) every registered
/// tool must
///   * declare a well-formed object schema whose `required` fields are
///     declared properties,
///   * answer a call missing its required fields with `invalidArguments`
///     naming exactly those fields — never an exception,
///   * answer a wrongly-typed field the same way.
/// Plus the guard's own rules: a throwing handler answers `toolFailed`, and
/// an `ok:false` body is flagged `isError`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart'
    show BuiltinToolRegistry, PatchPipelineImpl, WorkspaceCanonicalImpl;
import 'package:appplayer_studio/src/apps/app_builder/conv/dart_converter.dart';
import 'package:appplayer_studio/src/apps/app_builder/conv/embed_converter.dart';
import 'package:appplayer_studio/src/apps/app_builder/conv/self_ui_converter.dart';
import 'package:appplayer_studio/src/apps/app_builder/infra/server_bootstrap.dart';
import 'package:appplayer_studio/src/apps/form_builder/tools/form_builder_tools.dart';
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/tools/system_tools.dart';
import 'package:appplayer_studio/src/base/infra/workspace_fs_port.dart'
    show FileWorkspaceFsPort;
import 'package:appplayer_studio/src/base/spec/spec_validator.dart'
    show SpecValidatorImpl;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _body(mk.KernelToolResult r) =>
    jsonDecode(
          r.content.whereType<mk.KernelTextContent>().map((c) => c.text).join(),
        )
        as Map<String, dynamic>;

/// A value of the wrong JSON type for a property declared as [type].
Object? _wrongValueFor(Object? type) => switch (type) {
  'string' => 42,
  'number' || 'integer' => 'not-a-number',
  'boolean' => 'yes',
  'object' => 'not-an-object',
  'array' => 'not-an-array',
  _ => null,
};

/// Runs the per-tool contract over every tool on [host].
Future<void> _checkContract(mk.InProcessKernelServerHost host) async {
  final defs = host.toolDefinitions.toList();
  expect(defs, isNotEmpty);
  for (final def in defs) {
    final schema = def.inputSchema;
    final name = def.name;
    expect(schema['type'], 'object', reason: '$name schema type');
    final props = (schema['properties'] as Map?) ?? const <String, dynamic>{};
    final required =
        (schema['required'] as List?)?.cast<String>() ?? const <String>[];
    for (final field in required) {
      expect(
        props.containsKey(field),
        isTrue,
        reason: '$name requires undeclared "$field"',
      );
    }

    if (required.isNotEmpty) {
      final r = await host.callTool(name, <String, dynamic>{});
      expect(r.isError, isTrue, reason: '$name with no args');
      final body = _body(r);
      expect(body['code'], 'invalidArguments', reason: name);
      final missing = <String>{
        for (final e in (body['errors'] as List).cast<Map>())
          if (e['problem'] == 'missing') e['field'] as String,
      };
      expect(missing, required.toSet(), reason: name);
    }

    // First declared property with a checkable type gets a wrong value.
    for (final entry in props.entries) {
      final spec = entry.value;
      if (spec is! Map) continue;
      final wrong = _wrongValueFor(spec['type']);
      if (wrong == null) continue;
      final r = await host.callTool(name, <String, dynamic>{entry.key: wrong});
      expect(r.isError, isTrue, reason: '$name wrong ${entry.key}');
      final errors = (_body(r)['errors'] as List).cast<Map>();
      expect(
        errors.any((e) => e['field'] == entry.key && e['problem'] == 'type'),
        isTrue,
        reason: '$name must name ${entry.key} as mistyped',
      );
      break;
    }
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tool_contract_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('App Builder tools keep the call contract', () async {
    final canonical = WorkspaceCanonicalImpl(
      fsPort: FileWorkspaceFsPort(),
      validator: SpecValidatorImpl(),
    );
    await canonical.open('${tmp.path}/b.mbd');
    addTearDown(canonical.dispose);
    final host = mk.InProcessKernelServerHost(name: 'ab', version: '0');
    ServerBootstrap(
      server: BuiltinToolRegistry(host),
      canonical: canonical,
      pipeline: PatchPipelineImpl(
        canonical: canonical,
        validator: SpecValidatorImpl(),
      ),
      dartConv: DartConverterImpl(),
      embedConv: EmbedConverterImpl(),
      selfUiConv: SelfUiConverterImpl(),
    ).register();
    expect(host.toolDefinitions.length, greaterThanOrEqualTo(150));
    await _checkContract(host);
  });

  test('Ops tools keep the call contract', () async {
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
    final host = mk.InProcessKernelServerHost(name: 'ops', version: '0');
    SystemTools(init: init).registerOn(BuiltinToolRegistry(host));
    expect(host.toolDefinitions.length, greaterThanOrEqualTo(90));
    await _checkContract(host);
  });

  test('Form Builder tools keep the call contract', () async {
    final host = mk.InProcessKernelServerHost(name: 'form', version: '0');
    final server = BuiltinToolRegistry(host);
    FormBuilderTools(liveInit: () => null, server: server).registerOn(server);
    await _checkContract(host);
  });

  group('guard', () {
    late mk.InProcessKernelServerHost host;
    late BuiltinToolRegistry reg;
    const schema = <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mode': <String, dynamic>{
          'type': 'string',
          'enum': <String>['a', 'b'],
        },
        'count': <String, dynamic>{'type': 'integer'},
      },
    };

    setUp(() {
      host = mk.InProcessKernelServerHost(name: 'g', version: '0');
      reg = BuiltinToolRegistry(host);
    });

    test('a throwing handler answers toolFailed instead of throwing', () async {
      reg.addTool(
        name: 't.throw',
        description: '',
        inputSchema: schema,
        handler: (_) async => throw StateError('bridge slot not wired'),
      );
      final r = await host.callTool('t.throw', <String, dynamic>{});
      expect(r.isError, isTrue);
      final body = _body(r);
      expect(body['code'], 'toolFailed');
      expect(body['error'], contains('bridge slot not wired'));
    });

    test('an ok:false body is flagged isError', () async {
      reg.addTool(
        name: 't.notok',
        description: '',
        inputSchema: schema,
        handler:
            (_) async => mk.KernelToolResult(
              content: <mk.KernelContent>[
                mk.KernelTextContent(
                  text: jsonEncode(<String, dynamic>{
                    'ok': false,
                    'error': 'agent host not wired',
                  }),
                ),
              ],
            ),
      );
      final r = await host.callTool('t.notok', <String, dynamic>{});
      expect(r.isError, isTrue);
      expect(_body(r)['error'], 'agent host not wired');
    });

    test(
      'values outside an enum are rejected; valid calls pass through',
      () async {
        var calls = 0;
        reg.addTool(
          name: 't.ok',
          description: '',
          inputSchema: schema,
          handler: (_) async {
            calls++;
            return mk.KernelToolResult(
              content: <mk.KernelContent>[
                mk.KernelTextContent(text: jsonEncode({'ok': true})),
              ],
            );
          },
        );
        final bad = await host.callTool('t.ok', <String, dynamic>{'mode': 'z'});
        expect(bad.isError, isTrue);
        expect((_body(bad)['errors'] as List).single['problem'], 'enum');

        final good = await host.callTool('t.ok', <String, dynamic>{
          'mode': 'a',
          // A whole-number double is an integer in JSON.
          'count': 3.0,
        });
        expect(good.isError, isNot(isTrue));
        expect(calls, 1);
      },
    );
  });
}
