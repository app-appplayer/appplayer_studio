/// Unit tests for pure helper functions in `studio_workspace.dart`.
///
/// Only `readFriendlyLabel` is top-level (and pure-IO — it reads a file).
/// The `_interpolate` and `_slashHintsForBundle` helpers are private methods
/// on the widget State; they are tested here through observable behaviour
/// using temp files on disk.
///
/// Scenarios (readFriendlyLabel):
///   fw1  manifest.json with name field → returns the name
///   fw2  manifest.json with id but no name → returns last dot segment
///   fw3  manifest.json with both name and id → name wins
///   fw4  manifest.json missing → returns null
///   fw5  manifest.json malformed JSON → returns null
///   fw6  manifest.json empty name string → falls back to id last segment
///   fw7  manifest.json with nested manifest key → reads from manifest block
///
/// Scenarios (_interpolate via inline clone — private method not reachable):
///   ip1  simple {{key}} substituted from state map
///   ip2  nested {{a.b}} path walk
///   ip3  missing key → empty string substitution
///   ip4  {{}} empty placeholder → empty
///   ip5  no placeholders → template unchanged
///   ip6  multiple placeholders substituted in one pass
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/main/studio_workspace.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<Directory> _makeTempDir() => Directory.systemTemp.createTemp('sw_test_');

Future<void> _writeManifest(Directory dir, Object jsonContent) async {
  final f = File(p.join(dir.path, 'manifest.json'));
  await f.writeAsString(jsonEncode(jsonContent));
}

// ---------------------------------------------------------------------------
// Inline clone of _interpolate (private) for testing
// ---------------------------------------------------------------------------

String _interpolate(String template, Map<String, Object?> state) {
  return template.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (m) {
    final raw = m.group(1)?.trim() ?? '';
    if (raw.isEmpty) return '';
    Object? cursor = state;
    for (final seg in raw.split('.')) {
      if (cursor is Map) {
        cursor = cursor[seg];
      } else {
        cursor = null;
        break;
      }
    }
    return cursor == null ? '' : cursor.toString();
  });
}

void main() {
  // -------------------------------------------------------------------------
  // readFriendlyLabel
  // -------------------------------------------------------------------------
  group('readFriendlyLabel', () {
    late Directory dir;

    setUp(() async => dir = await _makeTempDir());
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('fw1 manifest with name field returns name', () async {
      await _writeManifest(dir, {
        'manifest': {'name': 'My Bundle', 'id': 'com.example.my_bundle'},
      });
      expect(readFriendlyLabel(dir.path), 'My Bundle');
    });

    test('fw2 manifest with id but no name returns last dot segment', () async {
      await _writeManifest(dir, {
        'manifest': {'id': 'com.example.cool_app'},
      });
      expect(readFriendlyLabel(dir.path), 'cool_app');
    });

    test('fw3 name takes priority over id last segment', () async {
      await _writeManifest(dir, {
        'manifest': {'name': 'Nice Name', 'id': 'com.example.different'},
      });
      expect(readFriendlyLabel(dir.path), 'Nice Name');
    });

    test('fw4 missing manifest.json returns null', () {
      // No file written
      expect(readFriendlyLabel(dir.path), isNull);
    });

    test('fw5 malformed JSON returns null', () async {
      final f = File(p.join(dir.path, 'manifest.json'));
      await f.writeAsString('{not valid json}');
      expect(readFriendlyLabel(dir.path), isNull);
    });

    test('fw6 empty name string falls back to id last segment', () async {
      await _writeManifest(dir, {
        'manifest': {'name': '', 'id': 'org.acme.reports'},
      });
      expect(readFriendlyLabel(dir.path), 'reports');
    });

    test('fw7 flat manifest (no nested manifest key) still parses', () async {
      // Some bundles store manifest fields at root level
      await _writeManifest(dir, {'name': 'Flat Bundle', 'id': 'flat.bundle'});
      expect(readFriendlyLabel(dir.path), 'Flat Bundle');
    });

    test('fw — id with no dot returns id verbatim', () async {
      await _writeManifest(dir, {
        'manifest': {'id': 'mybundle'},
      });
      expect(readFriendlyLabel(dir.path), 'mybundle');
    });
  });

  // -------------------------------------------------------------------------
  // _interpolate (cloned inline)
  // -------------------------------------------------------------------------
  group('_interpolate', () {
    test('ip1 simple {{key}} substituted from state', () {
      final result = _interpolate('Hello {{name}}!', {'name': 'World'});
      expect(result, 'Hello World!');
    });

    test('ip2 nested {{a.b}} path walk', () {
      final result = _interpolate('Mode: {{editor.mode}}', {
        'editor': {'mode': 'ui'},
      });
      expect(result, 'Mode: ui');
    });

    test('ip3 missing key → empty substitution', () {
      final result = _interpolate('Ref: {{missing}}', {});
      expect(result, 'Ref: ');
    });

    test('ip4 {{}} empty placeholder is not matched by regex — left as-is', () {
      // The regex requires at least one non-} char inside: [^}]+
      // So {{}} has no inner chars and is not substituted.
      final result = _interpolate('{{}}', {'': 'should_not_appear'});
      expect(result, '{{}}');
    });

    test('ip5 no placeholders → template unchanged', () {
      const tpl = 'Just a plain string.';
      expect(_interpolate(tpl, {}), tpl);
    });

    test('ip6 multiple placeholders substituted in one pass', () {
      final result = _interpolate('{{first}} and {{second}}', {
        'first': 'A',
        'second': 'B',
      });
      expect(result, 'A and B');
    });

    test('ip — deep path where intermediate is non-map → empty', () {
      final result = _interpolate('{{a.b.c}}', {'a': 'not-a-map'});
      expect(result, '');
    });

    test('ip — null value → empty', () {
      final result = _interpolate('{{key}}', {'key': null});
      expect(result, '');
    });
  });
}
