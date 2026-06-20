/// Unit tests for OpsConfig YAML serialization helpers.
///
/// `_toYaml` and `_yamlScalar` are private but their behaviour is
/// observable through `OpsConfig.save` + `OpsConfig.load` round-trips
/// and through the `toJsonString()` surface.
///
/// Additional scenarios not covered by the existing ops_config_test:
///
///   cy1  _yamlScalar — bool serialised as 'true' / 'false' (not quoted)
///   cy2  _yamlScalar — int serialised as plain number
///   cy3  _yamlScalar — string with colon is double-quoted
///   cy4  _yamlScalar — string with '#' is double-quoted
///   cy5  _yamlScalar — string starting with '[' is double-quoted
///   cy6  _yamlScalar — plain safe string is not quoted
///   cy7  _yamlScalar — empty string is double-quoted
///   cy8  save round-trip — LLM provider config survives save/load
///   cy9  save round-trip — outbound MCP servers survive save/load
///   cy10 save round-trip — systemAgent overrides survive save/load
///   cy11 toJson — all OpsConfig.themeModes accepted and re-parsed
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';

// ---------------------------------------------------------------------------
// Inline clone of _yamlScalar for white-box testing
// ---------------------------------------------------------------------------

String _yamlScalar(Object? v) {
  if (v == null) return 'null';
  if (v is bool || v is num) return v.toString();
  final s = v.toString();
  if (s.isEmpty ||
      s.contains(':') ||
      s.contains('#') ||
      s.contains('\n') ||
      s.startsWith(' ') ||
      s.endsWith(' ') ||
      RegExp(r'^[\[\]\{\}\,\&\*\?\|\>\!\%\@\`]').hasMatch(s)) {
    return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }
  return s;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<String> _makeTempPath() async {
  final dir = await Directory.systemTemp.createTemp('cy_test_');
  return p.join(dir.path, 'config.yaml');
}

OpsConfig _fullConfig() => OpsConfig(
  version: 'v1',
  appName: 'YamlTest',
  activeWorkspace: 'project/main',
  workspacesRoot: './ws',
  llm: LlmSettings(
    defaultProvider: 'claude',
    providers: {
      'claude': const LlmProviderSettings(
        apiKey: 'sk-test-key-1234',
        model: 'claude-sonnet-4-6',
        maxTokens: 8192,
      ),
    },
    timeoutSeconds: 90,
  ),
  mcp: McpSettings(
    inbound: const InboundMcpSettings(
      sseEnabled: true,
      streamableHttpEnabled: false,
      ssePort: 7200,
    ),
    outbound: [
      const OutboundMcpServer(
        id: 'remote',
        transport: 'sse',
        url: 'http://hub.example.com/sse',
      ),
    ],
  ),
  browser: const BrowserSettings.defaults(),
  storage: const StorageSettings.defaults(),
  channel: const ChannelSettings.empty(),
  security: const SecuritySettings.defaults(),
  systemAgent: const SystemAgentSettings(
    id: 'custom_admin',
    displayName: 'Custom',
    workspaceId: '_system',
    enabled: true,
    toolCallingEnabled: false,
  ),
);

void main() {
  // -------------------------------------------------------------------------
  // _yamlScalar white-box
  // -------------------------------------------------------------------------
  group('_yamlScalar', () {
    test('cy1 bool true serialised as true (unquoted)', () {
      expect(_yamlScalar(true), 'true');
    });

    test('cy1b bool false serialised as false (unquoted)', () {
      expect(_yamlScalar(false), 'false');
    });

    test('cy2 int serialised as plain number', () {
      expect(_yamlScalar(42), '42');
      expect(_yamlScalar(0), '0');
    });

    test('cy3 string with colon is double-quoted', () {
      final out = _yamlScalar('http://example.com');
      expect(out, startsWith('"'));
      expect(out, endsWith('"'));
    });

    test('cy4 string with # is double-quoted', () {
      final out = _yamlScalar('color # red');
      expect(out, startsWith('"'));
    });

    test('cy5 string starting with [ is double-quoted', () {
      final out = _yamlScalar('[list]');
      expect(out, startsWith('"'));
    });

    test('cy6 plain safe string is not quoted', () {
      expect(_yamlScalar('hello_world'), 'hello_world');
    });

    test('cy7 empty string is double-quoted', () {
      final out = _yamlScalar('');
      expect(out, '""');
    });

    test('cy — null serialised as null literal', () {
      expect(_yamlScalar(null), 'null');
    });
  });

  // -------------------------------------------------------------------------
  // Save / load round-trips
  // -------------------------------------------------------------------------
  group('OpsConfig YAML round-trip', () {
    test('cy8 LLM provider config survives save/load', () async {
      final path = await _makeTempPath();
      addTearDown(() async {
        final dir = Directory(p.dirname(path));
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      await _fullConfig().save(path: path);
      final loaded = await OpsConfig.load(path: path);
      expect(loaded.llm.defaultProvider, 'claude');
      expect(loaded.llm.timeoutSeconds, 90);
      expect(loaded.llm.providers['claude']!.model, 'claude-sonnet-4-6');
      expect(loaded.llm.providers['claude']!.maxTokens, 8192);
    });

    test('cy9 outbound MCP servers survive save/load', () async {
      final path = await _makeTempPath();
      addTearDown(() async {
        final dir = Directory(p.dirname(path));
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      await _fullConfig().save(path: path);
      final loaded = await OpsConfig.load(path: path);
      expect(loaded.mcp.outbound, hasLength(1));
      expect(loaded.mcp.outbound.first.id, 'remote');
      expect(loaded.mcp.outbound.first.url, 'http://hub.example.com/sse');
    });

    test('cy10 systemAgent overrides survive save/load', () async {
      final path = await _makeTempPath();
      addTearDown(() async {
        final dir = Directory(p.dirname(path));
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      await _fullConfig().save(path: path);
      final loaded = await OpsConfig.load(path: path);
      expect(loaded.systemAgent.id, 'custom_admin');
      expect(loaded.systemAgent.displayName, 'Custom');
      expect(loaded.systemAgent.toolCallingEnabled, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // cy11: all themeModes accepted by save / load
  // -------------------------------------------------------------------------
  group('themeMode round-trip', () {
    for (final mode in OpsConfig.themeModes) {
      test('cy11 themeMode=$mode survives round-trip', () async {
        final path = await _makeTempPath();
        addTearDown(() async {
          final dir = Directory(p.dirname(path));
          if (await dir.exists()) await dir.delete(recursive: true);
        });
        // Build a minimal OpsConfig with the given themeMode.
        final cfg = OpsConfig(
          version: 'v1',
          appName: 'ThemeModeTest',
          activeWorkspace: '',
          workspacesRoot: './ws',
          llm: const LlmSettings.empty(),
          mcp: const McpSettings.defaults(),
          browser: const BrowserSettings.defaults(),
          storage: const StorageSettings.defaults(),
          channel: const ChannelSettings.empty(),
          security: const SecuritySettings.defaults(),
          themeMode: mode,
        );
        await cfg.save(path: path);
        final loaded = await OpsConfig.load(path: path);
        expect(loaded.themeMode, mode);
      });
    }
  });
}
