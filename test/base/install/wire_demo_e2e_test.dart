import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:brain_kernel/mcp_host.dart' as mh;

/// End-to-end exercise of the example/wire_demo.mbd sample bundle —
/// the canonical Phase 5.6 testbed. Loads the on-disk bundle, runs
/// it through the activation pipeline, calls the registered tool,
/// and asserts the response shape that `mcp_ui_runtime`'s tool
/// action contract expects to auto-merge into page state.
///
/// If this test passes, the wiring path the sample's `ui/app.json`
/// declares (Button onTap → tool → result auto-merge → Text bind)
/// is honoured by every layer below the runtime: bundle parser,
/// activation context, JsHostBridge, JsToolRuntime.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Resolve the example bundle path relative to the test file. We
  /// assume the test runs from the package root (`dart test` /
  /// `flutter test` default).
  String _samplePath() {
    return p.normalize(
      p.join(Directory.current.path, 'example', 'wire_demo.mbd'),
    );
  }

  group('wire_demo.mbd e2e', () {
    test('manifest parses with tools, requires (empty), ui sections', () {
      final bundle = readBundleAt(_samplePath())!;
      expect(bundle.bundleId, 'com.makemind.examples.wire_demo');
      expect(bundle.shortId, 'wire_demo');
      expect(bundle.displayLabel, 'Wire Demo');
      expect(bundle.tools!.tools.single.name, 'shout');
      expect(bundle.tools!.tools.single.kind.name, 'js');
      expect(bundle.tools!.tools.single.inputSchema, isNotNull);
      expect(bundle.tools!.tools.single.outputSchema, isNotNull);
      expect(bundle.requires, isNotNull);
      expect(bundle.requires!.builtinAtoms, isEmpty);
      expect(bundle.uiEntry!.kind, 'mcp_ui_dsl');
      expect(bundle.uiEntry!.path, 'ui/app.json');
    });

    test('manifest passes validator with no errors', () {
      final bundle = readBundleAt(_samplePath())!;
      final issues = BundleManifestValidator.validate(bundle);
      final errors =
          issues
              .where((i) => i.severity == ManifestIssueSeverity.error)
              .toList();
      expect(
        errors,
        isEmpty,
        reason: errors
            .map((e) => '${e.code} @ ${e.pointer}: ${e.message}')
            .join('\n'),
      );
    });

    test('ui/app.json is valid JSON and references the registered tool', () {
      final uiFile = File(p.join(_samplePath(), 'ui', 'app.json'));
      expect(uiFile.existsSync(), isTrue);
      final raw = jsonDecode(uiFile.readAsStringSync()) as Map<String, dynamic>;
      // Walk the tree looking for the Button whose onTap dispatches
      // the tool. Confirms the wiring path the testbed depends on.
      bool found = false;
      void scan(dynamic node) {
        if (node is Map) {
          final tap = node['onTap'];
          if (tap is Map &&
              tap['action'] == 'tool' &&
              tap['tool'] == 'wire_demo.shout') {
            found = true;
          }
          for (final v in node.values) {
            scan(v);
          }
        } else if (node is List) {
          for (final v in node) {
            scan(v);
          }
        }
      }

      scan(raw);
      expect(
        found,
        isTrue,
        reason: 'ui/app.json must declare onTap → tool wire_demo.shout',
      );
    });

    test(
      'activation registers the tool and the call returns shouted text',
      () async {
        final bundle = readBundleAt(_samplePath())!;
        final boot = mk.InProcessKernelServerHost();
        final ctx = HostBundleActivationContext(
          boot: boot,
          tabKey: bundle.directory!,
          bundle: bundle,
          exposedShortId: bundle.shortId,
        );
        addTearDown(ctx.unregisterAll);

        // Phase 5.5 gate: empty requires.builtinTools is satisfied
        // trivially.
        expect(ctx.validateBuiltinTools(), isTrue);

        final reg = await ctx.registerTool(bundle.tools!.tools.single);
        expect(reg.ok, isTrue, reason: reg.error ?? 'register failed');
        expect(reg.exposedName, 'wire_demo.shout');

        final result = await boot.callTool('wire_demo.shout', const {
          'text': 'hello world',
        });
        expect(result.isError, isFalse);
        final body = (result.content.single as mk.KernelTextContent).text;
        // The tool returns `{shouted: <UPPER>}`. mcp_ui_runtime's tool
        // action will auto-merge top-level keys into page state — so
        // the Text widget bound to `{{shouted}}` picks it up without
        // any manual bindResult setting.
        expect(jsonDecode(body), {'shouted': 'HELLO WORLD'});
      },
    );
  });
}
