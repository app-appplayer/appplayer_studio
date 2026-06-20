/// `BundleManifestView` — top-level metadata editor for a bundle's
/// `manifest.json`. `_load()` is synchronous (existsSync /
/// readAsStringSync) so testWidgets is safe. When the file is absent
/// the widget shows a "No manifest.json" empty-state immediately.
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

  group('BundleManifestView — no manifest', () {
    testWidgets(
      'shows empty-state when bundlePath does not contain a manifest',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const BundleManifestView(bundlePath: '/tmp/__no_such_bundle__'),
          ),
        );
        // Single pump — synchronous _load() runs during initState.
        await tester.pump();
        expect(find.textContaining('No manifest'), findsOneWidget);
      },
    );

    testWidgets('includes bundlePath in empty-state text', (tester) async {
      const path = '/tmp/__bundle_manifest_view_test__';
      await tester.pumpWidget(
        _wrap(const BundleManifestView(bundlePath: path)),
      );
      await tester.pump();
      expect(find.textContaining(path), findsOneWidget);
    });
  });

  group('BundleManifestView — with manifest', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('vbu_bundle_manifest_view_');
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    Future<void> _writeManifest(Map<String, dynamic> data) async {
      final f = File('${tmpDir.path}/manifest.json');
      f.writeAsStringSync(jsonEncode(data));
    }

    testWidgets('renders id and version read-only rows', (tester) async {
      await _writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{
          'id': 'my-bundle',
          'name': 'My Bundle',
          'version': '1.2.3',
        },
      });
      await tester.pumpWidget(
        _wrap(BundleManifestView(bundlePath: tmpDir.path)),
      );
      await tester.pump();
      expect(find.text('my-bundle'), findsOneWidget);
      expect(find.text('1.2.3'), findsOneWidget);
    });

    testWidgets('renders IDENTITY section header', (tester) async {
      await _writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{
          'id': 'x',
          'name': 'X',
          'version': '0.1.0',
        },
      });
      await tester.pumpWidget(
        _wrap(BundleManifestView(bundlePath: tmpDir.path)),
      );
      await tester.pump();
      expect(find.textContaining('IDENTITY'), findsOneWidget);
    });

    testWidgets('renders CAPABILITY section header', (tester) async {
      await _writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 'x', 'name': 'X', 'version': '1'},
      });
      await tester.pumpWidget(
        _wrap(BundleManifestView(bundlePath: tmpDir.path)),
      );
      await tester.pump();
      expect(find.textContaining('CAPABILITY'), findsOneWidget);
    });

    testWidgets('shows AppPlayer-runnable badge for plain bundle', (
      tester,
    ) async {
      await _writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{
          'id': 'app',
          'name': 'App',
          'version': '1',
        },
      });
      await tester.pumpWidget(
        _wrap(BundleManifestView(bundlePath: tmpDir.path)),
      );
      await tester.pump();
      expect(find.textContaining('AppPlayer-runnable'), findsOneWidget);
    });

    testWidgets('shows Studio-extended badge when wiring.lifecycle is set', (
      tester,
    ) async {
      await _writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{
          'id': 'studio',
          'name': 'S',
          'version': '1',
        },
        'wiring': <String, dynamic>{
          'lifecycle': <dynamic>[
            <String, dynamic>{'event': 'onActivate', 'tool': 'my.activate'},
          ],
        },
      });
      await tester.pumpWidget(
        _wrap(BundleManifestView(bundlePath: tmpDir.path)),
      );
      await tester.pump();
      expect(find.textContaining('Studio-extended'), findsOneWidget);
    });

    testWidgets('renders REQUIRES section with atom count', (tester) async {
      await _writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 'a', 'name': 'A', 'version': '1'},
        'requires': <String, dynamic>{
          'builtinAtoms': <dynamic>['vbu.chat', 'vbu.inspector'],
        },
      });
      await tester.pumpWidget(
        _wrap(BundleManifestView(bundlePath: tmpDir.path)),
      );
      await tester.pump();
      expect(find.textContaining('builtinAtoms'), findsOneWidget);
    });

    testWidgets('shows chat agent when declared', (tester) async {
      await _writeManifest(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 'c', 'name': 'C', 'version': '1'},
        'chat': <String, dynamic>{'agent': 'my-agent'},
      });
      await tester.pumpWidget(
        _wrap(BundleManifestView(bundlePath: tmpDir.path)),
      );
      await tester.pump();
      expect(find.text('my-agent'), findsOneWidget);
    });

    testWidgets('flat top-level identity shape is also tolerated', (
      tester,
    ) async {
      await _writeManifest(<String, dynamic>{
        'id': 'flat-id',
        'name': 'Flat Bundle',
        'version': '0.0.1',
      });
      await tester.pumpWidget(
        _wrap(BundleManifestView(bundlePath: tmpDir.path)),
      );
      await tester.pump();
      expect(find.text('flat-id'), findsOneWidget);
    });
  });
}
