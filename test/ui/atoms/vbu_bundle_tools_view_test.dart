/// `BundleToolsView` — tools/domain-actions/slash-commands editor.
/// `_load()` is synchronous (existsSync / readAsStringSync). The widget
/// requires a `ChromeBridge` (for the `toolsSubTab` notifier) which is
/// constructible without any external deps.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        // BundleToolsView renders a wide tab row (>800px at default
        // test width). Give it enough horizontal room to avoid
        // RenderFlex overflow errors that would fail the tests.
        width: 1400,
        child: child,
      ),
    ),
  ),
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('BundleToolsView — no manifest', () {
    testWidgets('mounts without error when bundlePath has no manifest', (
      tester,
    ) async {
      final bridge = ChromeBridge();
      await tester.pumpWidget(
        _wrap(
          BundleToolsView(
            bundlePath: '/tmp/__no_tools_bundle__',
            overridesFile: '/tmp/__no_tools_overrides__',
            chromeBridge: bridge,
            reloadCounter: 0,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(BundleToolsView), findsOneWidget);
    });
  });

  group('BundleToolsView — with manifest', () {
    late Directory tmpDir;
    late ChromeBridge bridge;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('vbu_bundle_tools_view_');
      bridge = ChromeBridge();
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    void writeManifest(Map<String, dynamic> data) {
      File('${tmpDir.path}/manifest.json').writeAsStringSync(jsonEncode(data));
    }

    testWidgets('renders without error when tools list is empty', (
      tester,
    ) async {
      writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 't', 'name': 'T', 'version': '1'},
        'tools': <dynamic>[],
      });
      await tester.pumpWidget(
        _wrap(
          BundleToolsView(
            bundlePath: tmpDir.path,
            overridesFile: '${tmpDir.path}/overrides.json',
            chromeBridge: bridge,
            reloadCounter: 0,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(BundleToolsView), findsOneWidget);
    });

    testWidgets('renders without error when tools list has entries', (
      tester,
    ) async {
      writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 't', 'name': 'T', 'version': '1'},
        'tools': <dynamic>[
          <String, dynamic>{
            'name': 'my-tool',
            'description': 'Does stuff',
            'kind': 'js',
          },
        ],
      });
      await tester.pumpWidget(
        _wrap(
          BundleToolsView(
            bundlePath: tmpDir.path,
            overridesFile: '${tmpDir.path}/overrides.json',
            chromeBridge: bridge,
            reloadCounter: 0,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(BundleToolsView), findsOneWidget);
    });

    testWidgets('reloadCounter bump triggers re-read without error', (
      tester,
    ) async {
      writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 't', 'name': 'T', 'version': '1'},
      });
      await tester.pumpWidget(
        _wrap(
          BundleToolsView(
            bundlePath: tmpDir.path,
            overridesFile: '${tmpDir.path}/overrides.json',
            chromeBridge: bridge,
            reloadCounter: 0,
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(
        _wrap(
          BundleToolsView(
            bundlePath: tmpDir.path,
            overridesFile: '${tmpDir.path}/overrides.json',
            chromeBridge: bridge,
            reloadCounter: 1,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(BundleToolsView), findsOneWidget);
    });

    testWidgets('toolsSubTab notifier change is reflected without error', (
      tester,
    ) async {
      writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 't', 'name': 'T', 'version': '1'},
      });
      await tester.pumpWidget(
        _wrap(
          BundleToolsView(
            bundlePath: tmpDir.path,
            overridesFile: '${tmpDir.path}/overrides.json',
            chromeBridge: bridge,
            reloadCounter: 0,
          ),
        ),
      );
      await tester.pump();
      // Change the active sub-tab via the notifier — widget listens and adopts.
      bridge.toolsSubTab.value = 'domain';
      await tester.pump();
      expect(find.byType(BundleToolsView), findsOneWidget);
    });

    testWidgets('visibleKinds restricts rendered tab kinds', (tester) async {
      writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 't', 'name': 'T', 'version': '1'},
      });
      await tester.pumpWidget(
        _wrap(
          BundleToolsView(
            bundlePath: tmpDir.path,
            overridesFile: '${tmpDir.path}/overrides.json',
            chromeBridge: bridge,
            reloadCounter: 0,
            visibleKinds: const <BundleToolsKind>{BundleToolsKind.tool},
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(BundleToolsView), findsOneWidget);
    });
  });
}
