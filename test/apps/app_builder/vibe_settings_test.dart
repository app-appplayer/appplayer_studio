/// Unit tests for [VibeSettings] — the tool-level settings class used by
/// App Builder (and every other builder) to persist workspace / MCP / LLM
/// configuration.
///
/// The App Builder `infra/vibe_settings.dart` is a thin re-export of
/// `lib/src/base/settings/vibe_settings.dart`; this suite covers the full
/// public surface via the canonical import.
///
/// Scenario set:
///   vs1   defaults: mcpTransport='http', autosaveDelaySec=5, themeMode='system'
///   vs2   bumpRecent() moves path to head, dedupes, caps at limit
///   vs3   bumpRecent() ignores empty string
///   vs4   bumpRecent() updates lastProjectPath
///   vs5   bumpRecentSearch() moves query to head, dedupes, caps at limit
///   vs6   bumpRecentSearch() ignores blank / whitespace-only strings
///   vs7   toJson() omits null / empty optional fields
///   vs8   toJson() includes all set optional fields
///   vs9   fromJson() round-trips through toJson()
///   vs10  fromJson() uses defaults for missing / invalid fields
///   vs11  fromJson() normalises mcpServerUrl with bare path
///   vs12  fromJson() leaves mcpServerUrl with /mcp path unchanged
///   vs13  load() returns defaults when file is absent
///   vs14  load() parses a valid file and returns correct VibeSettings
///   vs15  load() returns defaults when file contains invalid JSON
///   vs16  save() writes a valid JSON file, load() reads it back
///   vs17  save() is atomic — uses a .tmp rename
///   vs18  keyFor() returns null for missing / empty provider entries
///   vs19  keyFor() returns the stored key for a known provider
///   vs20  defaultPath() builds ~/.config/<toolId>/settings.json shape
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart' show VibeSettings;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vibe_settings_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  String settingsPath() => p.join(tmp.path, 'settings.json');

  // ── vs1: defaults ─────────────────────────────────────────────────────────

  test('vs1: default VibeSettings has expected field values', () {
    final s = VibeSettings();
    expect(s.mcpTransport, 'http');
    expect(s.autosaveDelaySec, 5);
    expect(s.themeMode, 'system');
    expect(s.debugMode, isFalse);
    expect(s.recentProjects, isEmpty);
    expect(s.recentSearches, isEmpty);
    expect(s.llmProviders, isEmpty);
    expect(s.lastProjectPath, isNull);
  });

  // ── vs2: bumpRecent ───────────────────────────────────────────────────────

  test(
    'vs2: bumpRecent() prepends, dedupes, and caps at recentProjectsLimit',
    () {
      final s = VibeSettings();
      // Fill beyond the limit (8).
      for (var i = 0; i < VibeSettings.recentProjectsLimit + 3; i++) {
        s.bumpRecent('/project/$i');
      }
      expect(s.recentProjects.length, VibeSettings.recentProjectsLimit);
      // Most recent is at head.
      expect(
        s.recentProjects.first,
        '/project/${VibeSettings.recentProjectsLimit + 2}',
      );

      // Bumping an existing entry dedupes it to head.
      s.bumpRecent('/project/0');
      expect(s.recentProjects.first, '/project/0');
      expect(s.recentProjects.where((e) => e == '/project/0').length, 1);
    },
  );

  // ── vs3: bumpRecent ignores empty ─────────────────────────────────────────

  test('vs3: bumpRecent() ignores empty string', () {
    final s = VibeSettings();
    s.bumpRecent('');
    expect(s.recentProjects, isEmpty);
    expect(s.lastProjectPath, isNull);
  });

  // ── vs4: bumpRecent updates lastProjectPath ───────────────────────────────

  test('vs4: bumpRecent() updates lastProjectPath', () {
    final s = VibeSettings();
    s.bumpRecent('/my/project');
    expect(s.lastProjectPath, '/my/project');
  });

  // ── vs5: bumpRecentSearch ─────────────────────────────────────────────────

  test('vs5: bumpRecentSearch() prepends, dedupes, and caps at limit', () {
    final s = VibeSettings();
    for (var i = 0; i < VibeSettings.recentSearchesLimit + 2; i++) {
      s.bumpRecentSearch('query $i');
    }
    expect(s.recentSearches.length, VibeSettings.recentSearchesLimit);
    expect(
      s.recentSearches.first,
      'query ${VibeSettings.recentSearchesLimit + 1}',
    );

    // Deduplication.
    s.bumpRecentSearch('query 0');
    expect(s.recentSearches.first, 'query 0');
    expect(s.recentSearches.where((q) => q == 'query 0').length, 1);
  });

  // ── vs6: bumpRecentSearch ignores blank ───────────────────────────────────

  test('vs6: bumpRecentSearch() ignores blank / whitespace-only strings', () {
    final s = VibeSettings();
    s.bumpRecentSearch('   ');
    s.bumpRecentSearch('');
    expect(s.recentSearches, isEmpty);
  });

  // ── vs7: toJson omits nulls / empties ─────────────────────────────────────

  test('vs7: toJson() omits null and empty optional fields', () {
    final s = VibeSettings();
    final j = s.toJson();
    // These are null/empty by default and should be absent from JSON.
    expect(j.containsKey('workspaceDir'), isFalse);
    expect(j.containsKey('mcpServerUrl'), isFalse);
    expect(j.containsKey('llmApiKey'), isFalse);
    expect(j.containsKey('llmModel'), isFalse);
    expect(j.containsKey('recentProjects'), isFalse);
    expect(j.containsKey('debugMode'), isFalse);
    // These always appear.
    expect(j.containsKey('mcpTransport'), isTrue);
    expect(j.containsKey('autosaveDelaySec'), isTrue);
    expect(j.containsKey('themeMode'), isTrue);
  });

  // ── vs8: toJson includes set optional fields ──────────────────────────────

  test('vs8: toJson() includes all non-null / non-empty optional fields', () {
    final s = VibeSettings(
      workspaceDir: '/ws',
      mcpServerUrl: 'http://localhost:7840/mcp',
      llmApiKey: 'key123',
      llmModel: 'claude-opus-4',
      llmEndpoint: 'https://api.example.com',
      llmProviders: <String, String>{'anthropic': 'sk-ant'},
      lastProjectPath: '/proj',
      recentProjects: <String>['/a', '/b'],
      chatPanelWidth: 320.0,
      propsPanelWidth: 280.0,
      autosaveDelaySec: 10,
      recentSearches: <String>['foo'],
      themeMode: 'dark',
      debugMode: true,
    );
    final j = s.toJson();
    expect(j['workspaceDir'], '/ws');
    expect(j['mcpServerUrl'], 'http://localhost:7840/mcp');
    expect(j['llmApiKey'], 'key123');
    expect(j['llmModel'], 'claude-opus-4');
    expect(j['llmEndpoint'], 'https://api.example.com');
    expect((j['llmProviders'] as Map)['anthropic'], 'sk-ant');
    expect(j['lastProjectPath'], '/proj');
    expect(j['recentProjects'], <String>['/a', '/b']);
    expect(j['chatPanelWidth'], 320.0);
    expect(j['propsPanelWidth'], 280.0);
    expect(j['autosaveDelaySec'], 10);
    expect(j['recentSearches'], <String>['foo']);
    expect(j['themeMode'], 'dark');
    expect(j['debugMode'], isTrue);
  });

  // ── vs9: fromJson round-trip ──────────────────────────────────────────────

  test('vs9: fromJson() round-trips a fully-populated VibeSettings', () {
    final original = VibeSettings(
      workspaceDir: '/ws',
      llmApiKey: 'abc',
      llmModel: 'gpt-4',
      llmProviders: <String, String>{'openai': 'sk-openai'},
      lastProjectPath: '/p',
      recentProjects: <String>['/p'],
      themeMode: 'light',
      debugMode: true,
      autosaveDelaySec: 3,
    );
    final restored = VibeSettings.fromJson(original.toJson());
    expect(restored.workspaceDir, original.workspaceDir);
    expect(restored.llmApiKey, original.llmApiKey);
    expect(restored.llmModel, original.llmModel);
    expect(restored.llmProviders['openai'], 'sk-openai');
    expect(restored.lastProjectPath, original.lastProjectPath);
    expect(restored.recentProjects, <String>['/p']);
    expect(restored.themeMode, 'light');
    expect(restored.debugMode, isTrue);
    expect(restored.autosaveDelaySec, 3);
  });

  // ── vs10: fromJson defaults for missing fields ────────────────────────────

  test('vs10: fromJson() uses defaults for missing / invalid fields', () {
    // Minimal JSON — only required-by-real-use fields present.
    final s = VibeSettings.fromJson(const <String, dynamic>{});
    expect(s.mcpTransport, 'http');
    expect(s.autosaveDelaySec, 5);
    expect(s.themeMode, 'system');
    expect(s.debugMode, isFalse);
    expect(s.recentProjects, isEmpty);

    // Invalid themeMode falls back to 'system'.
    final s2 = VibeSettings.fromJson(<String, dynamic>{'themeMode': 'purple'});
    expect(s2.themeMode, 'system');
  });

  // ── vs11: fromJson normalises bare mcpServerUrl ───────────────────────────

  test('vs11: fromJson() appends /mcp to bare host URL', () {
    final s = VibeSettings.fromJson(<String, dynamic>{
      'mcpServerUrl': 'http://localhost:7840',
    });
    expect(s.mcpServerUrl, 'http://localhost:7840/mcp');
  });

  test('vs11b: fromJson() also appends /mcp to URL with trailing slash', () {
    final s = VibeSettings.fromJson(<String, dynamic>{
      'mcpServerUrl': 'http://localhost:7840/',
    });
    expect(s.mcpServerUrl, 'http://localhost:7840/mcp');
  });

  // ── vs12: fromJson leaves /mcp path untouched ─────────────────────────────

  test('vs12: fromJson() leaves an already-correct /mcp URL unchanged', () {
    final s = VibeSettings.fromJson(<String, dynamic>{
      'mcpServerUrl': 'http://127.0.0.1:7830/mcp',
    });
    expect(s.mcpServerUrl, 'http://127.0.0.1:7830/mcp');
  });

  // ── vs13: load() returns defaults for missing file ────────────────────────

  test(
    'vs13: load() returns default VibeSettings when file is absent',
    () async {
      final s = await VibeSettings.load(p.join(tmp.path, 'absent.json'));
      expect(s.mcpTransport, 'http');
      expect(s.recentProjects, isEmpty);
    },
  );

  // ── vs14: load() parses a valid file ─────────────────────────────────────

  test('vs14: load() parses a valid settings.json correctly', () async {
    final path = settingsPath();
    final json = jsonEncode(<String, dynamic>{
      'llmModel': 'claude-3-5',
      'themeMode': 'dark',
      'autosaveDelaySec': 7,
    });
    await File(path).writeAsString(json);
    final s = await VibeSettings.load(path);
    expect(s.llmModel, 'claude-3-5');
    expect(s.themeMode, 'dark');
    expect(s.autosaveDelaySec, 7);
  });

  // ── vs15: load() returns defaults on corrupt file ─────────────────────────

  test(
    'vs15: load() returns default VibeSettings when file contains invalid JSON',
    () async {
      final path = settingsPath();
      await File(path).writeAsString('this is { not JSON');
      final s = await VibeSettings.load(path);
      expect(s.mcpTransport, 'http');
      expect(s.themeMode, 'system');
    },
  );

  // ── vs16: save() + load() round-trip ─────────────────────────────────────

  test(
    'vs16: save() writes a valid JSON file that load() reads back correctly',
    () async {
      final path = settingsPath();
      final original = VibeSettings(
        llmApiKey: 'round-trip-key',
        llmModel: 'gemini-pro',
        themeMode: 'light',
        autosaveDelaySec: 2,
      );
      await original.save(path);
      expect(await File(path).exists(), isTrue);

      final restored = await VibeSettings.load(path);
      expect(restored.llmApiKey, 'round-trip-key');
      expect(restored.llmModel, 'gemini-pro');
      expect(restored.themeMode, 'light');
      expect(restored.autosaveDelaySec, 2);
    },
  );

  // ── vs17: save() is atomic ────────────────────────────────────────────────

  test('vs17: save() does not leave a .tmp file after completion', () async {
    final path = settingsPath();
    await VibeSettings().save(path);
    expect(await File('$path.tmp').exists(), isFalse);
    expect(await File(path).exists(), isTrue);
  });

  // ── vs18: keyFor() ────────────────────────────────────────────────────────

  test('vs18: keyFor() returns null for missing or empty provider entry', () {
    final s = VibeSettings(
      llmProviders: <String, String>{'anthropic': '', 'openai': 'sk'},
    );
    expect(s.keyFor(null), isNull);
    expect(
      s.keyFor('anthropic'),
      isNull,
      reason: 'empty string counts as null',
    );
    expect(s.keyFor('unknown'), isNull);
  });

  // ── vs19: keyFor() returns stored key ────────────────────────────────────

  test('vs19: keyFor() returns the stored key for a known provider', () {
    final s = VibeSettings(
      llmProviders: <String, String>{'anthropic': 'sk-ant-123'},
    );
    expect(s.keyFor('anthropic'), 'sk-ant-123');
  });

  // ── vs20: defaultPath() ───────────────────────────────────────────────────

  test('vs20: defaultPath() ends with <toolId>/settings.json', () {
    final path = VibeSettings.defaultPath('app_builder_vibe');
    expect(path, endsWith(p.join('app_builder_vibe', 'settings.json')));
  });
}
