/// Extended unit tests for `VibeSettings` pure-logic:
///   s1  keyFor — null providerId, present key, missing key, empty value
///   s2  bumpRecentSearch — dedup, head-of-list, trim whitespace, cap at limit
///   s3  bumpRecent — dedup, MRU order, cap at recentProjectsLimit, sets lastProjectPath
///   s4  fromJson / toJson round-trip — transport, themeMode, llmProviders, browser fields
///   s5  _normalizeMcpUrl (via fromJson) — bare host gets /mcp appended, full path preserved
///   s6  _validThemeMode — 'light' and 'dark' pass; anything else → 'system'
///   s7  defaultPath — composes ~/.config/<toolId>/settings.json
///   s8  save + load — atomic write, re-read equal fields
///   s9  load missing file → default instance
///   s10 load corrupt JSON → default instance
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/settings/vibe_settings.dart';

void main() {
  // ---------------------------------------------------------------------------
  // s1 — keyFor
  // ---------------------------------------------------------------------------
  group('s1 keyFor', () {
    test('returns null for null providerId', () {
      final s = VibeSettings(llmProviders: {'anthropic': 'sk-abc'});
      expect(s.keyFor(null), isNull);
    });

    test('returns the key when providerId is present', () {
      final s = VibeSettings(llmProviders: {'anthropic': 'sk-abc'});
      expect(s.keyFor('anthropic'), 'sk-abc');
    });

    test('returns null when providerId is absent from the map', () {
      final s = VibeSettings(llmProviders: {'anthropic': 'sk-abc'});
      expect(s.keyFor('openai'), isNull);
    });

    test('treats empty string value as null', () {
      final s = VibeSettings(llmProviders: {'anthropic': ''});
      expect(s.keyFor('anthropic'), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // s2 — bumpRecentSearch
  // ---------------------------------------------------------------------------
  group('s2 bumpRecentSearch', () {
    test('adds a new query to the head', () {
      final s = VibeSettings();
      s.bumpRecentSearch('hello');
      expect(s.recentSearches.first, 'hello');
    });

    test('trims whitespace before inserting', () {
      final s = VibeSettings();
      s.bumpRecentSearch('  padded  ');
      expect(s.recentSearches.first, 'padded');
    });

    test('ignores blank/whitespace-only queries', () {
      final s = VibeSettings();
      s.bumpRecentSearch('   ');
      expect(s.recentSearches, isEmpty);
    });

    test('deduplicates: moves existing entry to head', () {
      final s = VibeSettings(recentSearches: ['b', 'c']);
      s.bumpRecentSearch('c');
      expect(s.recentSearches, ['c', 'b']);
    });

    test('caps list at recentSearchesLimit', () {
      final s = VibeSettings();
      for (var i = 0; i < VibeSettings.recentSearchesLimit + 5; i++) {
        s.bumpRecentSearch('q$i');
      }
      expect(s.recentSearches.length, VibeSettings.recentSearchesLimit);
    });

    test('newest entry is always at the head', () {
      final s = VibeSettings();
      s.bumpRecentSearch('first');
      s.bumpRecentSearch('second');
      expect(s.recentSearches.first, 'second');
    });
  });

  // ---------------------------------------------------------------------------
  // s3 — bumpRecent
  // ---------------------------------------------------------------------------
  group('s3 bumpRecent', () {
    test('adds path to head and updates lastProjectPath', () {
      final s = VibeSettings();
      s.bumpRecent('/home/user/proj');
      expect(s.recentProjects.first, '/home/user/proj');
      expect(s.lastProjectPath, '/home/user/proj');
    });

    test('ignores empty path', () {
      final s = VibeSettings();
      s.bumpRecent('');
      expect(s.recentProjects, isEmpty);
      expect(s.lastProjectPath, isNull);
    });

    test('deduplicates and moves to head', () {
      final s = VibeSettings(recentProjects: ['/a', '/b', '/c']);
      s.bumpRecent('/b');
      expect(s.recentProjects, ['/b', '/a', '/c']);
    });

    test('caps at recentProjectsLimit', () {
      final s = VibeSettings();
      for (var i = 0; i < VibeSettings.recentProjectsLimit + 3; i++) {
        s.bumpRecent('/proj/$i');
      }
      expect(s.recentProjects.length, VibeSettings.recentProjectsLimit);
    });

    test('head is always newest', () {
      final s = VibeSettings();
      s.bumpRecent('/old');
      s.bumpRecent('/new');
      expect(s.recentProjects.first, '/new');
    });
  });

  // ---------------------------------------------------------------------------
  // s4 — fromJson / toJson round-trip
  // ---------------------------------------------------------------------------
  group('s4 fromJson / toJson round-trip', () {
    test('basic fields survive the round-trip', () {
      final s = VibeSettings(
        workspaceDir: '/ws',
        mcpTransport: 'sse',
        llmModel: 'claude-opus-4',
        autosaveDelaySec: 10,
        themeMode: 'dark',
        debugMode: true,
      );
      final json = s.toJson();
      final s2 = VibeSettings.fromJson(json);
      expect(s2.workspaceDir, '/ws');
      expect(s2.mcpTransport, 'sse');
      expect(s2.llmModel, 'claude-opus-4');
      expect(s2.autosaveDelaySec, 10);
      expect(s2.themeMode, 'dark');
      expect(s2.debugMode, isTrue);
    });

    test('llmProviders map survives round-trip', () {
      final s = VibeSettings(
        llmProviders: {'anthropic': 'sk-1', 'openai': 'sk-2'},
      );
      final s2 = VibeSettings.fromJson(s.toJson());
      expect(s2.llmProviders['anthropic'], 'sk-1');
      expect(s2.llmProviders['openai'], 'sk-2');
    });

    test('recentProjects list survives round-trip', () {
      final s = VibeSettings(recentProjects: ['/a', '/b']);
      final s2 = VibeSettings.fromJson(s.toJson());
      expect(s2.recentProjects, ['/a', '/b']);
    });

    test('browser fields survive round-trip', () {
      final s = VibeSettings(
        chromiumPath: '/usr/bin/chromium',
        maxBrowserContexts: 20,
        browserUserAgent: 'TestBot',
        browserLocale: 'en-US',
        browserTimezone: 'UTC',
        browserViewportWidth: 1280,
        browserViewportHeight: 720,
        browserRespectRobots: true,
      );
      final s2 = VibeSettings.fromJson(s.toJson());
      expect(s2.chromiumPath, '/usr/bin/chromium');
      expect(s2.maxBrowserContexts, 20);
      expect(s2.browserUserAgent, 'TestBot');
      expect(s2.browserLocale, 'en-US');
      expect(s2.browserTimezone, 'UTC');
      expect(s2.browserViewportWidth, 1280);
      expect(s2.browserViewportHeight, 720);
      expect(s2.browserRespectRobots, isTrue);
    });

    test('null optional fields are omitted from toJson', () {
      final s = VibeSettings();
      final json = s.toJson();
      expect(json.containsKey('workspaceDir'), isFalse);
      expect(json.containsKey('llmApiKey'), isFalse);
      expect(json.containsKey('lastProjectPath'), isFalse);
      expect(json.containsKey('chromiumPath'), isFalse);
    });

    test('debugMode=false is omitted from toJson', () {
      final json = VibeSettings(debugMode: false).toJson();
      expect(json.containsKey('debugMode'), isFalse);
    });

    test('debugMode=true is written to toJson', () {
      final json = VibeSettings(debugMode: true).toJson();
      expect(json['debugMode'], isTrue);
    });

    test('chatPanelWidth and propsPanelWidth survive round-trip', () {
      final s = VibeSettings(chatPanelWidth: 320.5, propsPanelWidth: 260.0);
      final s2 = VibeSettings.fromJson(s.toJson());
      expect(s2.chatPanelWidth, 320.5);
      expect(s2.propsPanelWidth, 260.0);
    });
  });

  // ---------------------------------------------------------------------------
  // s5 — _normalizeMcpUrl (exercised via fromJson)
  // ---------------------------------------------------------------------------
  group('s5 _normalizeMcpUrl via fromJson', () {
    test('bare host URL gets /mcp path appended', () {
      final s = VibeSettings.fromJson({
        'mcpServerUrl': 'http://127.0.0.1:7830',
      });
      expect(s.mcpServerUrl, 'http://127.0.0.1:7830/mcp');
    });

    test('URL with trailing slash gets /mcp path (replaces /)', () {
      final s = VibeSettings.fromJson({
        'mcpServerUrl': 'http://127.0.0.1:7830/',
      });
      expect(s.mcpServerUrl, 'http://127.0.0.1:7830/mcp');
    });

    test('URL already containing /mcp path is preserved unchanged', () {
      final s = VibeSettings.fromJson({
        'mcpServerUrl': 'http://127.0.0.1:7830/mcp',
      });
      expect(s.mcpServerUrl, 'http://127.0.0.1:7830/mcp');
    });

    test('URL with deeper path is preserved unchanged', () {
      final s = VibeSettings.fromJson({
        'mcpServerUrl': 'http://127.0.0.1:7830/studio/mcp',
      });
      expect(s.mcpServerUrl, 'http://127.0.0.1:7830/studio/mcp');
    });

    test('null mcpServerUrl stays null', () {
      final s = VibeSettings.fromJson(<String, dynamic>{});
      expect(s.mcpServerUrl, isNull);
    });

    test('empty string mcpServerUrl stays empty', () {
      final s = VibeSettings.fromJson({'mcpServerUrl': ''});
      // Empty string → _normalizeMcpUrl returns the empty string → fromJson omits
      // it since it's empty; the field comes back null.
      expect(s.mcpServerUrl == null || s.mcpServerUrl!.isEmpty, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // s6 — _validThemeMode
  // ---------------------------------------------------------------------------
  group('s6 _validThemeMode', () {
    test('"light" is accepted', () {
      final s = VibeSettings.fromJson({'themeMode': 'light'});
      expect(s.themeMode, 'light');
    });

    test('"dark" is accepted', () {
      final s = VibeSettings.fromJson({'themeMode': 'dark'});
      expect(s.themeMode, 'dark');
    });

    test('"system" falls through to system default', () {
      final s = VibeSettings.fromJson({'themeMode': 'system'});
      expect(s.themeMode, 'system');
    });

    test('unknown value falls back to "system"', () {
      final s = VibeSettings.fromJson({'themeMode': 'auto'});
      expect(s.themeMode, 'system');
    });

    test('missing themeMode field falls back to "system"', () {
      final s = VibeSettings.fromJson(<String, dynamic>{});
      expect(s.themeMode, 'system');
    });

    test('null themeMode falls back to "system"', () {
      final s = VibeSettings.fromJson({'themeMode': null});
      expect(s.themeMode, 'system');
    });
  });

  // ---------------------------------------------------------------------------
  // s7 — defaultPath
  // ---------------------------------------------------------------------------
  group('s7 defaultPath', () {
    test('composes ~.config/<toolId>/settings.json', () {
      final path = VibeSettings.defaultPath('my_tool');
      expect(p.basename(path), 'settings.json');
      expect(path, contains('my_tool'));
      expect(path, contains(p.join('.config', 'my_tool')));
    });

    test('different toolIds produce different paths', () {
      final p1 = VibeSettings.defaultPath('tool_a');
      final p2 = VibeSettings.defaultPath('tool_b');
      expect(p1, isNot(p2));
    });
  });

  // ---------------------------------------------------------------------------
  // s8 — save + load (fs-touching; each test uses its own temp dir)
  // ---------------------------------------------------------------------------
  group('s8 save + load', () {
    late Directory tmpDir;
    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('vibe_settings_test_');
    });
    tearDown(() async {
      if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
    });

    test('save writes valid JSON and load restores it', () async {
      final path = p.join(tmpDir.path, 'settings.json');
      final s = VibeSettings(
        workspaceDir: '/my/ws',
        mcpTransport: 'sse',
        themeMode: 'dark',
        autosaveDelaySec: 3,
      );
      await s.save(path);
      expect(File(path).existsSync(), isTrue);

      final loaded = await VibeSettings.load(path);
      expect(loaded.workspaceDir, '/my/ws');
      expect(loaded.mcpTransport, 'sse');
      expect(loaded.themeMode, 'dark');
      expect(loaded.autosaveDelaySec, 3);
    });

    test('save is atomic: temp file is renamed in place', () async {
      final path = p.join(tmpDir.path, 'settings.json');
      final s = VibeSettings(workspaceDir: '/atomic');
      await s.save(path);
      // The .tmp file must not exist after save completes.
      expect(File('$path.tmp').existsSync(), isFalse);
      expect(File(path).existsSync(), isTrue);
    });

    test('save creates parent directories on demand', () async {
      final path = p.join(tmpDir.path, 'nested', 'dir', 'settings.json');
      final s = VibeSettings(mcpTransport: 'http');
      await s.save(path);
      expect(File(path).existsSync(), isTrue);
    });

    test('recentProjects survive save + load', () async {
      final path = p.join(tmpDir.path, 'settings.json');
      final s = VibeSettings(recentProjects: ['/proj/a', '/proj/b']);
      await s.save(path);
      final loaded = await VibeSettings.load(path);
      expect(loaded.recentProjects, ['/proj/a', '/proj/b']);
    });
  });

  // ---------------------------------------------------------------------------
  // s9 — load missing file → default instance
  // ---------------------------------------------------------------------------
  group('s9 load missing file', () {
    test('returns default instance when path does not exist', () async {
      final s = await VibeSettings.load(
        '/tmp/__vibe_settings_nonexistent__.json',
      );
      // Default state: transport = 'http', themeMode = 'system'
      expect(s.mcpTransport, 'http');
      expect(s.themeMode, 'system');
      expect(s.recentProjects, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // s10 — load corrupt JSON → default instance
  // ---------------------------------------------------------------------------
  group('s10 load corrupt JSON', () {
    late Directory tmpDir;
    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('vibe_settings_corrupt_');
    });
    tearDown(() async {
      if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
    });

    test('returns default instance on JSON parse error', () async {
      final path = p.join(tmpDir.path, 'settings.json');
      await File(path).writeAsString('NOT JSON {{{');
      final s = await VibeSettings.load(path);
      expect(s.mcpTransport, 'http');
      expect(s.themeMode, 'system');
    });

    test(
      'returns default instance when root is a JSON array (not object)',
      () async {
        final path = p.join(tmpDir.path, 'settings.json');
        await File(path).writeAsString(jsonEncode(['a', 'b']));
        final s = await VibeSettings.load(path);
        expect(s.mcpTransport, 'http');
      },
    );
  });
}
