/// `BundleAgentsView` — agent list editor for a bundle.
/// `_load()` in initState is async (`await f.readAsString()`). Tests
/// use `tester.runAsync` + delay pattern so the real IO event loop
/// resolves the future before assertions run.
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

  group('BundleAgentsView — no manifest', () {
    testWidgets('mounts without error when bundlePath has no manifest', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const BundleAgentsView(bundlePath: '/tmp/__no_agents_bundle__')),
      );
      // First pump: widget is mounted; async _load() fires but hasn't
      // completed yet (file doesn't exist → returns quickly).
      await tester.pump();
      expect(find.byType(BundleAgentsView), findsOneWidget);
    });
  });

  group('BundleAgentsView — with manifest', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('vbu_bundle_agents_view_');
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    void writeManifest(Map<String, dynamic> data) {
      File('${tmpDir.path}/manifest.json').writeAsStringSync(jsonEncode(data));
    }

    testWidgets('renders without error when manifest has no agents', (
      tester,
    ) async {
      writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 'a', 'name': 'A', 'version': '1'},
      });
      await tester.pumpWidget(_wrap(BundleAgentsView(bundlePath: tmpDir.path)));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(find.byType(BundleAgentsView), findsOneWidget);
    });

    testWidgets('renders without error for canonical agents shape', (
      tester,
    ) async {
      writeManifest(<String, dynamic>{
        'agents': <String, dynamic>{
          'agents': <dynamic>[
            <String, dynamic>{'id': 'manager', 'role': 'manager'},
          ],
        },
      });
      await tester.pumpWidget(_wrap(BundleAgentsView(bundlePath: tmpDir.path)));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(find.byType(BundleAgentsView), findsOneWidget);
    });

    testWidgets('reloadCounter bump triggers re-read without error', (
      tester,
    ) async {
      writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 'a', 'name': 'A', 'version': '1'},
      });
      await tester.pumpWidget(
        _wrap(BundleAgentsView(bundlePath: tmpDir.path, reloadCounter: 0)),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pumpWidget(
        _wrap(BundleAgentsView(bundlePath: tmpDir.path, reloadCounter: 1)),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.byType(BundleAgentsView), findsOneWidget);
    });
  });
}
