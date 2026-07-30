/// Shared harness for Form Builder UI widget tests: a REAL `form.*` +
/// `form_builder.*` tool surface (in-process kernel host, fact-backed
/// template port, real file IO under a temp project) so page tests
/// exercise the exact wiring production uses — no mocks.
library;

import 'dart:convert' show jsonEncode;
import 'dart:io';

import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/builtin_api.dart' as mk;
import 'package:brain_kernel/brain_kernel.dart' as bk;

import 'package:appplayer_studio/src/base/install/capability_recipes/capability_recipes.dart'
    show CapabilityToolError, FactBackedFormTemplatePort, formCapabilityTools;
import 'package:appplayer_studio/src/base/install/capability_tools.dart'
    show withFormVocabularyGate;
import 'package:appplayer_studio/src/base/install/form_capability_store.dart'
    show KernelFormTemplateFactStore;
import 'package:appplayer_studio/src/apps/form_builder/init/form_init.dart';
import 'package:appplayer_studio/src/apps/form_builder/tools/form_builder_tools.dart';

class FormUiHarness {
  FormUiHarness._(this.server, this.init, this.projectRoot);

  final BuiltinToolRegistry server;
  final FormInit init;
  final Directory projectRoot;

  static Future<FormUiHarness> boot() async {
    final projectRoot = await Directory.systemTemp.createTemp('form_ui_');
    final init = await FormInit.boot(projectRoot.path, 'harness');
    final port = await FactBackedFormTemplatePort.hydrate(
      KernelFormTemplateFactStore(
        facts: init.system.facts,
        workspaceId: init.projectId,
      ),
    );
    final boot = bk.InProcessKernelServerHost();
    final server = BuiltinToolRegistry(boot);
    // Same envelope the host's capability bridge produces.
    for (final raw in formCapabilityTools(templatePort: port)) {
      // Same vocabulary gate production wires on save_template.
      final tool =
          raw.verb == 'save_template' ? withFormVocabularyGate(raw) : raw;
      server.addTool(
        name: 'form.${tool.verb}',
        description: tool.description,
        inputSchema: tool.inputSchema,
        handler: (args) => _guard(tool.invoke, args),
      );
    }
    // In-app notification stub — the approval verbs push through host
    // `channel.send`; the harness records instead of hanging on a tool the
    // in-process kernel host does not carry (tests can assert pushes).
    server.addTool(
      name: 'channel.send',
      description: 'harness in_app notification recorder',
      inputSchema: const <String, dynamic>{'type': 'object'},
      handler: (args) async {
        notifications.add(args);
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: jsonEncode({'ok': true})),
          ],
          isError: false,
        );
      },
    );
    final harness = FormUiHarness._(server, init, projectRoot);
    FormBuilderTools(liveInit: () => init, server: server)
        .registerOn(server);
    return harness;
  }

  /// `channel.send` pushes recorded by the harness stub, in order.
  static final List<Map<String, dynamic>> notifications =
      <Map<String, dynamic>>[];

  Future<void> dispose() async {
    if (await projectRoot.exists()) {
      await projectRoot.delete(recursive: true);
    }
  }

  static Future<mk.KernelToolResult> _guard(
    Future<Object?> Function(Map<String, dynamic>) invoke,
    Map<String, dynamic> args,
  ) async {
    try {
      final result = await invoke(args);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(result)),
        ],
        isError: false,
      );
    } on CapabilityToolError catch (e) {
      return _error(e.code, e.message);
    } catch (e) {
      return _error('capability.error', '$e');
    }
  }

  static mk.KernelToolResult _error(String code, String message) {
    return mk.KernelToolResult(
      content: <mk.KernelContent>[
        mk.KernelTextContent(
          text: jsonEncode(<String, dynamic>{
            'ok': false,
            'code': code,
            'error': message,
          }),
        ),
      ],
      isError: true,
    );
  }
}

/// A small template with one field and one table — the fixture most
/// UI-matrix tests fill against.
Map<String, dynamic> harnessTemplate({
  String id = 'harness-quote',
  String version = '1.0.0',
}) => {
  'templateId': id,
  'version': version,
  'name': 'Harness Quote',
  'schema': {
    'fields': [
      {'name': 'recipient', 'type': 'string'},
    ],
  },
  'defaultSections': [
    {
      'sectionId': 'main',
      'index': 0,
      'blocks': [
        {
          'blockId': 'title',
          'type': 'heading',
          'index': 0,
          'level': 1,
          'content': 'Quotation',
        },
        {
          'blockId': 'recv',
          'type': 'formField',
          'index': 1,
          'fieldName': 'recipient',
          'fieldType': 'text',
        },
        {
          'blockId': 'items',
          'type': 'table',
          'index': 2,
          'columns': [
            {'id': 'name', 'title': 'item', 'type': 'string'},
            {'id': 'amount', 'title': 'amount', 'type': 'string'},
          ],
          'rows': [
            {
              'cells': {'name': 'Default item', 'amount': '₩1'},
            },
          ],
        },
      ],
    },
  ],
  'layoutPolicy': {
    'pageSize': {'size': 'A4', 'width': 210, 'height': 297},
    'margins': {'top': 20, 'right': 20, 'bottom': 20, 'left': 20},
    'fontPolicy': {
      'defaultFont': 'sans-serif',
      'defaultSize': 12,
      'headingSize': 18,
      'bodySize': 12,
      'minSize': 8,
    },
  },
};
