/// `BundleKnowledgeView` — knowledge section editor for a bundle.
/// `_load()` is synchronous (existsSync / readAsStringSync) so
/// testWidgets is safe. When the bundle path has no manifest.json the
/// widget renders its empty-list state immediately.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('BundleKnowledgeView — no manifest', () {
    testWidgets('mounts without error when bundlePath has no manifest', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const BundleKnowledgeView(bundlePath: '/tmp/__no_knowledge_bundle__'),
        ),
      );
      await tester.pump();
      expect(find.byType(BundleKnowledgeView), findsOneWidget);
    });
  });

  group('BundleKnowledgeView — with manifest', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync(
        'vbu_bundle_knowledge_view_',
      );
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    void writeManifest(Map<String, dynamic> data) {
      File('${tmpDir.path}/manifest.json').writeAsStringSync(jsonEncode(data));
    }

    testWidgets('renders without error when knowledge section is empty', (
      tester,
    ) async {
      writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 'k', 'name': 'K', 'version': '1'},
        'knowledge': <String, dynamic>{},
      });
      await tester.pumpWidget(
        _wrap(BundleKnowledgeView(bundlePath: tmpDir.path)),
      );
      await tester.pump();
      expect(find.byType(BundleKnowledgeView), findsOneWidget);
    });

    testWidgets('renders without error when sources list is populated', (
      tester,
    ) async {
      writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 'k', 'name': 'K', 'version': '1'},
        'knowledge': <String, dynamic>{
          'sources': <dynamic>[
            <String, dynamic>{'id': 'src-1', 'name': 'My Source'},
          ],
        },
      });
      await tester.pumpWidget(
        _wrap(BundleKnowledgeView(bundlePath: tmpDir.path)),
      );
      await tester.pump();
      expect(find.byType(BundleKnowledgeView), findsOneWidget);
    });

    testWidgets('reloadCounter bump triggers rebuild without error', (
      tester,
    ) async {
      writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 'k', 'name': 'K', 'version': '1'},
      });
      await tester.pumpWidget(
        _wrap(BundleKnowledgeView(bundlePath: tmpDir.path, reloadCounter: 0)),
      );
      await tester.pump();
      // Simulate a reload trigger (e.g. chat mutator updated the manifest).
      await tester.pumpWidget(
        _wrap(BundleKnowledgeView(bundlePath: tmpDir.path, reloadCounter: 1)),
      );
      await tester.pump();
      expect(find.byType(BundleKnowledgeView), findsOneWidget);
    });

    testWidgets('tolerates agents in canonical wrapped shape', (tester) async {
      writeManifest(<String, dynamic>{
        'agents': <String, dynamic>{
          'agents': <dynamic>[
            <String, dynamic>{'id': 'agent-x'},
          ],
        },
      });
      await tester.pumpWidget(
        _wrap(BundleKnowledgeView(bundlePath: tmpDir.path)),
      );
      await tester.pump();
      expect(find.byType(BundleKnowledgeView), findsOneWidget);
    });

    testWidgets('tolerates agents in flat list shape', (tester) async {
      writeManifest(<String, dynamic>{
        'agents': <dynamic>[
          <String, dynamic>{'id': 'agent-y'},
        ],
      });
      await tester.pumpWidget(
        _wrap(BundleKnowledgeView(bundlePath: tmpDir.path)),
      );
      await tester.pump();
      expect(find.byType(BundleKnowledgeView), findsOneWidget);
    });
  });
}
