/// `ManifestFieldList` — schema-driven settings section renderer.
/// `_loadOverrides()` in initState is async (`await f.exists()`). Tests
/// that care about the post-load state use `tester.runAsync` to let the
/// real Dart IO event loop resolve the future, then pump after the
/// runAsync block to apply the resulting setState to the widget tree.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

// Non-existent path — File.exists() returns false immediately.
const _kOverridesPath = '/tmp/__nonexistent_overrides_mfl3__.json';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('ManifestFieldList — empty fields', () {
    testWidgets('renders (no fields) text when fields is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          ManifestFieldList(
            fields: const <Map<String, dynamic>>[],
            overridesFile: _kOverridesPath,
          ),
        ),
      );
      await tester.pump();
      // Empty fields path shows the placeholder immediately (not guarded by
      // _loaded) because the build method checks fields.isEmpty first.
      expect(find.textContaining('no fields'), findsOneWidget);
    });

    testWidgets('shows Loading text before async load finishes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          ManifestFieldList(
            fields: const <Map<String, dynamic>>[
              <String, dynamic>{'key': 'x', 'label': 'X', 'type': 'text'},
            ],
            overridesFile: _kOverridesPath,
          ),
        ),
      );
      // First pump: _loaded is still false (async not yet resolved).
      await tester.pump();
      expect(find.textContaining('Loading'), findsOneWidget);
    });
  });

  group('ManifestFieldList — with fields, no overrides file', () {
    testWidgets('renders text-type field label after async load completes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          ManifestFieldList(
            fields: const <Map<String, dynamic>>[
              <String, dynamic>{
                'key': 'url',
                'label': 'Server URL',
                'type': 'text',
              },
            ],
            overridesFile: _kOverridesPath,
          ),
        ),
      );
      // runAsync allows the real IO microtask (_loadOverrides) to complete.
      await tester.runAsync(() async {
        // Small delay so the async _loadOverrides future has time to resolve
        // (file absent → no read → setState immediately).
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      // Pump after runAsync so the setState rebuild reaches the widget tree.
      await tester.pump();
      expect(find.text('Server URL'), findsOneWidget);
    });

    testWidgets('renders toggle-type field label', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ManifestFieldList(
            fields: const <Map<String, dynamic>>[
              <String, dynamic>{
                'key': 'enabled',
                'label': 'Enable Feature',
                'type': 'toggle',
                'value': false,
              },
            ],
            overridesFile: _kOverridesPath,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.text('Enable Feature'), findsOneWidget);
    });

    testWidgets('renders multiple fields in order', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ManifestFieldList(
            fields: const <Map<String, dynamic>>[
              <String, dynamic>{'key': 'a', 'label': 'Alpha', 'type': 'text'},
              <String, dynamic>{'key': 'b', 'label': 'Beta', 'type': 'toggle'},
            ],
            overridesFile: _kOverridesPath,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('hides field when dependsOn condition is not met', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          ManifestFieldList(
            fields: const <Map<String, dynamic>>[
              <String, dynamic>{
                'key': 'toggle',
                'label': 'ShowChild',
                'type': 'toggle',
                'value': false,
              },
              <String, dynamic>{
                'key': 'child',
                'label': 'ChildField',
                'type': 'text',
                'dependsOn': 'toggle',
                'dependsOnValue': true,
              },
            ],
            overridesFile: _kOverridesPath,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.text('ShowChild'), findsOneWidget);
      // toggle effective value is false → child is hidden.
      expect(find.text('ChildField'), findsNothing);
    });

    testWidgets('shows field when dependsOn condition is met', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ManifestFieldList(
            fields: const <Map<String, dynamic>>[
              <String, dynamic>{
                'key': 'toggle',
                'label': 'ShowChild',
                'type': 'toggle',
                'value': true,
              },
              <String, dynamic>{
                'key': 'child',
                'label': 'ChildField',
                'type': 'text',
                'dependsOn': 'toggle',
                'dependsOnValue': true,
              },
            ],
            overridesFile: _kOverridesPath,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.text('ChildField'), findsOneWidget);
    });
  });

  group('ManifestFieldList — with overrides file', () {
    late Directory tmpDir;
    late File overridesFile;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('vbu_manifest_field_list_');
      overridesFile = File('${tmpDir.path}/overrides.json');
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    testWidgets('widget mounts without error when overrides file exists', (
      tester,
    ) async {
      overridesFile.writeAsStringSync(
        jsonEncode(<String, dynamic>{'serverUrl': 'https://example.com'}),
      );
      await tester.pumpWidget(
        _wrap(
          ManifestFieldList(
            fields: const <Map<String, dynamic>>[
              <String, dynamic>{
                'key': 'serverUrl',
                'label': 'Server',
                'type': 'text',
                'value': 'http://localhost',
              },
            ],
            overridesFile: overridesFile.path,
          ),
        ),
      );
      // First pump: widget is mounted; _loadOverrides() begins but hasn't
      // completed yet (file exists path requires multiple async hops).
      await tester.pump();
      // Widget is mounted and in "Loading..." state without error.
      expect(find.byType(ManifestFieldList), findsOneWidget);
    });
  });
}
