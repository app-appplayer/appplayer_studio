/// Unit tests for [VibeProjectPrefs] and [BuildConfig].
///
/// Scenario set:
///   pp1  defaults — all optional fields null, focusedByChannelMode empty
///   pp2  toJson — empty prefs produces only schemaVersion
///   pp3  toJson — populated prefs includes all set fields
///   pp4  fromJson round-trip — toJson → fromJson preserves values
///   pp5  fromJson — unknown CenterMode names ignored (no crash)
///   pp6  fromJson — unknown LayerId names ignored (no crash)
///   pp7  load — missing file returns defaults
///   pp8  load — corrupt file returns defaults
///   pp9  load — non-object JSON returns defaults
///   pp10 load/save round-trip — persists and restores all fields
///   pp11 save — atomic (tmp rename pattern)
///   bc1  BuildConfig.toJson / fromJson round-trip
///   bc2  BuildConfig.fromJson — missing fields use defaults
///   bc3  BuildConfig.copyWith — partial override
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/apps/app_builder/infra/vibe_project_prefs.dart';
import 'package:appplayer_studio/src/apps/app_builder/core/types.dart'
    show CenterMode;
import 'package:appplayer_studio/base.dart' show LayerId;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('prefs_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ── pp1 defaults ────────────────────────────────────────────────────
  group('pp1 defaults', () {
    test('focusedByChannelMode is empty', () {
      final p = VibeProjectPrefs();
      expect(p.focusedByChannelMode, isEmpty);
    });

    test('all optional fields are null', () {
      final prefs = VibeProjectPrefs();
      expect(prefs.selectedPageId, isNull);
      expect(prefs.selectedComponentId, isNull);
      expect(prefs.previewSizeChoice, isNull);
      expect(prefs.previewOrientation, isNull);
      expect(prefs.previewBrightness, isNull);
      expect(prefs.previewCustomW, isNull);
      expect(prefs.previewCustomH, isNull);
      expect(prefs.buildConfig, isNull);
    });
  });

  // ── pp2 toJson empty ────────────────────────────────────────────────
  group('pp2 toJson empty', () {
    test('only schemaVersion when nothing set', () {
      final json = VibeProjectPrefs().toJson();
      expect(json['schemaVersion'], 2);
      expect(json.containsKey('selectedPageId'), isFalse);
      expect(json.containsKey('focusedByChannelMode'), isFalse);
      expect(json.containsKey('buildConfig'), isFalse);
    });
  });

  // ── pp3 toJson populated ────────────────────────────────────────────
  group('pp3 toJson populated', () {
    test('includes all set string fields', () {
      final prefs = VibeProjectPrefs(
        selectedPageId: 'home',
        selectedComponentId: 'btn1',
        previewSizeChoice: 'mobile',
        previewOrientation: 'portrait',
        previewBrightness: 'dark',
        previewCustomW: 360,
        previewCustomH: 640,
      );
      final json = prefs.toJson();
      expect(json['selectedPageId'], 'home');
      expect(json['selectedComponentId'], 'btn1');
      expect(json['previewSizeChoice'], 'mobile');
      expect(json['previewOrientation'], 'portrait');
      expect(json['previewBrightness'], 'dark');
      expect(json['previewCustomW'], 360);
      expect(json['previewCustomH'], 640);
    });

    test('includes focusedByChannelMode when non-empty', () {
      final prefs = VibeProjectPrefs(
        focusedByChannelMode: <String, Map<CenterMode, LayerId>>{
          'serving': {CenterMode.ui: LayerId.pages},
        },
      );
      final json = prefs.toJson();
      expect(json.containsKey('focusedByChannelMode'), isTrue);
      final byChannel = json['focusedByChannelMode'] as Map;
      expect(byChannel.containsKey('serving'), isTrue);
    });

    test('includes buildConfig when set', () {
      final prefs = VibeProjectPrefs(
        buildConfig: const BuildConfig(
          target: 'mcpb',
          channel: 'serving',
          outDir: 'build/mcpb',
          runFlutterCreate: false,
        ),
      );
      final json = prefs.toJson();
      expect(json.containsKey('buildConfig'), isTrue);
    });
  });

  // ── pp4 round-trip ──────────────────────────────────────────────────
  group('pp4 fromJson round-trip', () {
    test('all fields survive toJson → fromJson', () {
      final original = VibeProjectPrefs(
        selectedPageId: 'pg1',
        selectedComponentId: 'cmp2',
        previewSizeChoice: 'tablet',
        previewOrientation: 'landscape',
        previewBrightness: 'light',
        previewCustomW: 768,
        previewCustomH: 1024,
        buildConfig: const BuildConfig(
          target: 'inline',
          channel: 'native',
          outDir: 'build/inline',
          runFlutterCreate: true,
        ),
        focusedByChannelMode: <String, Map<CenterMode, LayerId>>{
          'serving': {CenterMode.bundle: LayerId.manifest},
        },
      );
      final restored = VibeProjectPrefs.fromJson(original.toJson());
      expect(restored.selectedPageId, 'pg1');
      expect(restored.selectedComponentId, 'cmp2');
      expect(restored.previewSizeChoice, 'tablet');
      expect(restored.previewOrientation, 'landscape');
      expect(restored.previewBrightness, 'light');
      expect(restored.previewCustomW, 768);
      expect(restored.previewCustomH, 1024);
      expect(restored.buildConfig?.target, 'inline');
      expect(restored.buildConfig?.channel, 'native');
      expect(restored.buildConfig?.outDir, 'build/inline');
      expect(restored.buildConfig?.runFlutterCreate, isTrue);
    });

    test('focusedByChannelMode round-trips', () {
      final original = VibeProjectPrefs(
        focusedByChannelMode: <String, Map<CenterMode, LayerId>>{
          'serving': {CenterMode.ui: LayerId.pages},
          'native': {CenterMode.bundle: LayerId.tools},
        },
      );
      final restored = VibeProjectPrefs.fromJson(original.toJson());
      expect(
        restored.focusedByChannelMode['serving']?[CenterMode.ui],
        LayerId.pages,
      );
      expect(
        restored.focusedByChannelMode['native']?[CenterMode.bundle],
        LayerId.tools,
      );
    });
  });

  // ── pp5 unknown CenterMode ──────────────────────────────────────────
  group('pp5 unknown CenterMode name ignored', () {
    test('no crash, channel entry excluded when all mode names unknown', () {
      final json = <String, dynamic>{
        'focusedByChannelMode': {
          'serving': {'unknownMode': 'pages'},
        },
      };
      final prefs = VibeProjectPrefs.fromJson(json);
      // byMode is empty → channel key not inserted into focusMap.
      expect(prefs.focusedByChannelMode.containsKey('serving'), isFalse);
    });
  });

  // ── pp6 unknown LayerId ─────────────────────────────────────────────
  group('pp6 unknown LayerId name ignored', () {
    test('no crash, channel entry excluded when all layer names unknown', () {
      final json = <String, dynamic>{
        'focusedByChannelMode': {
          'serving': {'ui': 'unknownLayer'},
        },
      };
      final prefs = VibeProjectPrefs.fromJson(json);
      // byMode is empty (LayerId not recognized) → channel key not inserted.
      expect(prefs.focusedByChannelMode.containsKey('serving'), isFalse);
    });
  });

  // ── pp7 load missing file ───────────────────────────────────────────
  group('pp7 load missing file', () {
    test('returns empty defaults', () async {
      final prefs = await VibeProjectPrefs.load(tmp.path);
      expect(prefs.selectedPageId, isNull);
      expect(prefs.focusedByChannelMode, isEmpty);
    });
  });

  // ── pp8 load corrupt file ───────────────────────────────────────────
  group('pp8 load corrupt file', () {
    test('returns empty defaults on JSON parse error', () async {
      final file = File(p.join(tmp.path, VibeProjectPrefs.fileName));
      await file.writeAsString('{not valid json!}');
      final prefs = await VibeProjectPrefs.load(tmp.path);
      expect(prefs.selectedPageId, isNull);
    });
  });

  // ── pp9 load non-object JSON ────────────────────────────────────────
  group('pp9 load non-object JSON', () {
    test('returns empty defaults', () async {
      final file = File(p.join(tmp.path, VibeProjectPrefs.fileName));
      await file.writeAsString('[1,2,3]');
      final prefs = await VibeProjectPrefs.load(tmp.path);
      expect(prefs.selectedPageId, isNull);
    });
  });

  // ── pp10 load/save round-trip ───────────────────────────────────────
  group('pp10 save/load round-trip', () {
    test('persisted values survive save + load', () async {
      final prefs = VibeProjectPrefs(
        selectedPageId: 'page42',
        previewSizeChoice: 'pc',
        buildConfig: const BuildConfig(
          target: 'bundle',
          channel: 'serving',
          outDir: 'build/bundle',
          runFlutterCreate: false,
        ),
      );
      await prefs.save(tmp.path);
      final loaded = await VibeProjectPrefs.load(tmp.path);
      expect(loaded.selectedPageId, 'page42');
      expect(loaded.previewSizeChoice, 'pc');
      expect(loaded.buildConfig?.target, 'bundle');
      expect(loaded.buildConfig?.runFlutterCreate, isFalse);
    });
  });

  // ── pp11 save atomic ────────────────────────────────────────────────
  group('pp11 save atomic', () {
    test('no stray .tmp file after save', () async {
      await VibeProjectPrefs(selectedPageId: 'x').save(tmp.path);
      final tmpFile = File(
        p.join(tmp.path, '${VibeProjectPrefs.fileName}.tmp'),
      );
      expect(await tmpFile.exists(), isFalse);
    });

    test('written file is valid JSON', () async {
      await VibeProjectPrefs(selectedPageId: 'atomic').save(tmp.path);
      final file = File(p.join(tmp.path, VibeProjectPrefs.fileName));
      expect(await file.exists(), isTrue);
      final content = await file.readAsString();
      expect(() => jsonDecode(content), returnsNormally);
    });
  });

  // ── bc1 BuildConfig round-trip ──────────────────────────────────────
  group('bc1 BuildConfig toJson/fromJson', () {
    test('all fields survive round-trip', () {
      const bc = BuildConfig(
        target: 'native_inline',
        channel: 'native',
        outDir: 'build/native_inline',
        runFlutterCreate: true,
      );
      final restored = BuildConfig.fromJson(bc.toJson());
      expect(restored.target, 'native_inline');
      expect(restored.channel, 'native');
      expect(restored.outDir, 'build/native_inline');
      expect(restored.runFlutterCreate, isTrue);
    });
  });

  // ── bc2 BuildConfig defaults ─────────────────────────────────────────
  group('bc2 BuildConfig.fromJson defaults', () {
    test('missing fields use defaults', () {
      final bc = BuildConfig.fromJson(<String, dynamic>{});
      expect(bc.target, 'mcpb');
      expect(bc.channel, 'serving');
      expect(bc.outDir, '');
      expect(bc.runFlutterCreate, isTrue);
    });
  });

  // ── bc3 BuildConfig.copyWith ─────────────────────────────────────────
  group('bc3 BuildConfig.copyWith', () {
    test('partial override preserves unchanged fields', () {
      const bc = BuildConfig(
        target: 'bundle',
        channel: 'serving',
        outDir: 'build/bundle',
        runFlutterCreate: false,
      );
      final updated = bc.copyWith(target: 'inline');
      expect(updated.target, 'inline');
      expect(updated.channel, 'serving');
      expect(updated.outDir, 'build/bundle');
      expect(updated.runFlutterCreate, isFalse);
    });

    test('copyWith with no args returns equivalent object', () {
      const bc = BuildConfig(
        target: 'mcpb',
        channel: 'serving',
        outDir: '',
        runFlutterCreate: true,
      );
      final copy = bc.copyWith();
      expect(copy.target, bc.target);
      expect(copy.channel, bc.channel);
    });
  });
}
