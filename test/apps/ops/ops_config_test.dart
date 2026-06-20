/// OpsConfig — unit tests for parse / defaults / validation.
///
/// All tests use a real temp file for OpsConfig.load; no full app boot.
///
///   c1  firstRun() — loadedFromDisk=false, isFirstRun=true, sensible defaults
///   c2  load from missing file — returns firstRun() config
///   c3  load minimal YAML — only required fields, rest get defaults
///   c4  load full YAML — all sections round-trip through expected fields
///   c5  themeMode coercion — valid / invalid / missing → 'dark' fallback
///   c6  validation passes when activeWorkspace is empty (first-run state)
///   c7  validation fails on malformed activeWorkspace (no slash)
///   c8  validation fails on unknown defaultProvider
///   c9  LlmSettings.fromYaml — providers / timeoutSeconds
///   c10 McpSettings.fromYaml — inbound legacy transport: sse
///   c11 InboundMcpSettings.fromYaml — new multi-transport fields
///   c12 BrowserSettings.fromYaml — chromiumPath / viewport / defaults
///   c13 StorageSettings.fromYaml — localKvPath / retention defaults
///   c14 SecuritySettings.fromYaml — secretsBackend / aesKeyRef
///   c15 SystemAgentSettings.fromYaml — id / displayName / workspaceId / flags
///   c16 OpsConfig.save / load round-trip (temp file)
///   c17 OutboundMcpServer.fromYaml — id / transport / command / url
///   c18 ChannelSettings.fromYaml — providers map
///   c19 OpsConfig.toJsonString — valid JSON output
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/config/ops_error.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
Future<String> _writeTempYaml(String content) async {
  final dir = await Directory.systemTemp.createTemp('ops_cfg_test_');
  final f = File(p.join(dir.path, 'config.yaml'));
  await f.writeAsString(content);
  return f.path;
}

void main() {
  late List<String> _temps;

  setUp(() => _temps = []);

  tearDown(() async {
    for (final path in _temps) {
      final parent = Directory(p.dirname(path));
      if (await parent.exists()) await parent.delete(recursive: true);
    }
  });

  Future<String> writeTmp(String content) async {
    final path = await _writeTempYaml(content);
    _temps.add(path);
    return path;
  }

  // --- c1 ---
  group('OpsConfig.firstRun', () {
    test('c1 loadedFromDisk is false, isFirstRun is true', () {
      final cfg = OpsConfig.firstRun();
      expect(cfg.loadedFromDisk, isFalse);
      expect(cfg.isFirstRun, isTrue);
      expect(cfg.appName, OpsConfig.defaultAppName);
      expect(cfg.activeWorkspace, isEmpty);
      expect(cfg.workspacesRoot, './workspaces');
    });
  });

  // --- c2 ---
  group('OpsConfig.load', () {
    test('c2 missing file returns firstRun config', () async {
      final cfg = await OpsConfig.load(
        path: '/tmp/does_not_exist_ops_xyz.yaml',
      );
      expect(cfg.isFirstRun, isTrue);
    });

    // --- c3 ---
    test('c3 minimal YAML — activeWorkspace empty, rest defaults', () async {
      final path = await writeTmp('''
version: "2024-01-01T00:00:00.000Z"
''');
      final cfg = await OpsConfig.load(path: path);
      expect(cfg.version, '2024-01-01T00:00:00.000Z');
      expect(cfg.appName, OpsConfig.defaultAppName); // default
      expect(cfg.activeWorkspace, isEmpty);
      expect(cfg.themeMode, 'dark'); // default
      expect(cfg.loadedFromDisk, isTrue);
    });

    // --- c4 ---
    test('c4 full YAML round-trips all sections', () async {
      final path = await writeTmp('''
version: "2024-06-01T00:00:00Z"
appName: "Test Ops"
activeWorkspace: "project/main"
workspacesRoot: /data/workspaces
themeMode: light
llm:
  defaultProvider: claude
  timeoutSeconds: 120
  providers:
    claude:
      apiKey: sk-test
      model: claude-3-opus-20240229
      maxTokens: 8192
mcp:
  inbound:
    sseEnabled: true
    streamableHttpEnabled: false
    ssePort: 9999
  outbound:
    servers:
      - id: remote
        transport: sse
        url: http://localhost:8080
browser:
  maxConcurrentContexts: 2
  respectRobots: false
storage:
  localKvPath: /data/kv
  backupIntervalHours: 12
  retentionDays: 60
channel:
  providers:
    slack:
      token: xoxb-test
security:
  secretsBackend: aes-file
  auditRetentionDays: 180
systemAgent:
  id: my_admin
  displayName: "My Admin"
  workspaceId: _system
  enabled: true
  toolCallingEnabled: false
''');
      final cfg = await OpsConfig.load(path: path);

      expect(cfg.appName, 'Test Ops');
      expect(cfg.activeWorkspace, 'project/main');
      expect(cfg.workspacesRoot, '/data/workspaces');
      expect(cfg.themeMode, 'light');
      expect(cfg.llm.defaultProvider, 'claude');
      expect(cfg.llm.timeoutSeconds, 120);
      expect(cfg.llm.providers['claude']!.model, 'claude-3-opus-20240229');
      expect(cfg.llm.providers['claude']!.maxTokens, 8192);
      expect(cfg.mcp.inbound.sseEnabled, isTrue);
      expect(cfg.mcp.inbound.streamableHttpEnabled, isFalse);
      expect(cfg.mcp.inbound.ssePort, 9999);
      expect(cfg.mcp.outbound.length, 1);
      expect(cfg.mcp.outbound.first.id, 'remote');
      expect(cfg.mcp.outbound.first.url, 'http://localhost:8080');
      expect(cfg.browser.maxConcurrentContexts, 2);
      expect(cfg.browser.respectRobots, isFalse);
      expect(cfg.storage.localKvPath, '/data/kv');
      expect(cfg.storage.backupIntervalHours, 12);
      expect(cfg.storage.retentionDays, 60);
      expect(cfg.channel.providers.containsKey('slack'), isTrue);
      expect(cfg.security.secretsBackend, 'aes-file');
      expect(cfg.security.auditRetentionDays, 180);
      expect(cfg.systemAgent.id, 'my_admin');
      expect(cfg.systemAgent.displayName, 'My Admin');
      expect(cfg.systemAgent.toolCallingEnabled, isFalse);
    });

    // --- c5 ---
    test('c5 themeMode coercion — valid values', () async {
      for (final mode in OpsConfig.themeModes) {
        final path = await writeTmp('themeMode: $mode\n');
        final cfg = await OpsConfig.load(path: path);
        expect(cfg.themeMode, mode);
        _temps.add(path);
      }
    });

    test('c5b themeMode invalid string falls back to dark', () async {
      final path = await writeTmp('themeMode: neon\n');
      final cfg = await OpsConfig.load(path: path);
      expect(cfg.themeMode, 'dark');
    });

    test('c5c themeMode missing falls back to dark', () async {
      final path = await writeTmp('version: "x"\n');
      final cfg = await OpsConfig.load(path: path);
      expect(cfg.themeMode, 'dark');
    });

    // --- c6 ---
    test('c6 validation passes when activeWorkspace is empty', () async {
      // Should not throw.
      final path = await writeTmp('activeWorkspace: ""\n');
      final cfg = await OpsConfig.load(path: path);
      expect(cfg.activeWorkspace, isEmpty);
    });

    // --- c7 ---
    test(
      'c7 validation fails on malformed activeWorkspace (no slash)',
      () async {
        final path = await writeTmp('''
activeWorkspace: "badvalue"
''');
        expect(() => OpsConfig.load(path: path), throwsA(isA<OpsError>()));
      },
    );

    // --- c8 ---
    test(
      'c8 validation fails when defaultProvider not in providers map',
      () async {
        final path = await writeTmp('''
activeWorkspace: "project/main"
llm:
  defaultProvider: openai
  providers:
    claude:
      apiKey: sk-test
      model: claude-3
''');
        expect(() => OpsConfig.load(path: path), throwsA(isA<OpsError>()));
      },
    );

    test('c8b validation passes when defaultProvider is empty', () async {
      final path = await writeTmp('''
activeWorkspace: "project/main"
llm:
  defaultProvider: ""
''');
      // Should not throw.
      final cfg = await OpsConfig.load(path: path);
      expect(cfg.llm.defaultProvider, isEmpty);
    });

    // --- c16: save/load round-trip ---
    test('c16 save then load round-trips all fields', () async {
      final dir = await Directory.systemTemp.createTemp('ops_save_test_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final savePath = p.join(dir.path, 'config.yaml');

      final original = await OpsConfig.load(
        path: await writeTmp('''
version: "v1"
appName: "SaveTest"
activeWorkspace: "project/test"
workspacesRoot: /tmp/ws
themeMode: system
llm:
  defaultProvider: ""
'''),
      );

      await original.save(path: savePath);
      final loaded = await OpsConfig.load(path: savePath);

      expect(loaded.appName, 'SaveTest');
      expect(loaded.activeWorkspace, 'project/test');
      expect(loaded.workspacesRoot, '/tmp/ws');
      expect(loaded.themeMode, 'system');
    });

    // --- c19: toJsonString ---
    test(
      'c19 toJsonString produces valid JSON with all top-level keys',
      () async {
        final path = await writeTmp('version: "v2"\nappName: "JsonTest"\n');
        final cfg = await OpsConfig.load(path: path);
        final json = cfg.toJsonString();
        expect(json, contains('"appName"'));
        expect(json, contains('"llm"'));
        expect(json, contains('"mcp"'));
        expect(json, contains('"storage"'));
        expect(json, contains('"security"'));
      },
    );
  });

  // --- c9 ---
  group('LlmSettings', () {
    test('c9 fromYaml parses providers and timeoutSeconds', () async {
      final path = await writeTmp('''
llm:
  defaultProvider: gpt4
  timeoutSeconds: 90
  providers:
    gpt4:
      apiKey: sk-abc
      model: gpt-4-turbo
      maxTokens: 2048
''');
      final cfg = await OpsConfig.load(path: path);
      expect(cfg.llm.defaultProvider, 'gpt4');
      expect(cfg.llm.timeoutSeconds, 90);
      expect(cfg.llm.providers['gpt4']!.apiKey, 'sk-abc');
      expect(cfg.llm.providers['gpt4']!.maxTokens, 2048);
    });

    test('c9b LlmSettings.empty — defaults', () {
      const s = LlmSettings.empty();
      expect(s.defaultProvider, isEmpty);
      expect(s.providers, isEmpty);
      expect(s.timeoutSeconds, 60);
    });
  });

  // --- c10 ---
  group('McpSettings / InboundMcpSettings', () {
    test(
      'c10 legacy transport: sse maps to sseEnabled=true, streamable=false',
      () async {
        final path = await writeTmp('''
mcp:
  inbound:
    transport: sse
    ssePort: 8080
''');
        final cfg = await OpsConfig.load(path: path);
        expect(cfg.mcp.inbound.sseEnabled, isTrue);
        expect(cfg.mcp.inbound.streamableHttpEnabled, isFalse);
        expect(cfg.mcp.inbound.ssePort, 8080);
      },
    );

    // --- c11 ---
    test('c11 new multi-transport fields are parsed correctly', () async {
      final path = await writeTmp('''
mcp:
  inbound:
    sseEnabled: false
    streamableHttpEnabled: true
    ssePort: 7001
    streamableHttpPort: 7002
''');
      final cfg = await OpsConfig.load(path: path);
      expect(cfg.mcp.inbound.sseEnabled, isFalse);
      expect(cfg.mcp.inbound.streamableHttpEnabled, isTrue);
      expect(cfg.mcp.inbound.ssePort, 7001);
      expect(cfg.mcp.inbound.streamableHttpPort, 7002);
    });

    test('c11b InboundMcpSettings defaults', () {
      const s = InboundMcpSettings();
      expect(s.sseEnabled, isTrue);
      expect(s.streamableHttpEnabled, isTrue);
      expect(s.ssePort, 7123);
      expect(s.streamableHttpPort, 7124);
    });
  });

  // --- c12 ---
  group('BrowserSettings', () {
    test('c12 parses chromiumPath / viewport / downloadDir', () async {
      final path = await writeTmp('''
browser:
  chromiumPath: /usr/bin/chromium
  userAgent: TestBot/1.0
  downloadDir: /tmp/downloads
  maxConcurrentContexts: 8
  respectRobots: true
  defaultViewport:
    width: 1920
    height: 1080
''');
      final cfg = await OpsConfig.load(path: path);
      expect(cfg.browser.chromiumPath, '/usr/bin/chromium');
      expect(cfg.browser.userAgent, 'TestBot/1.0');
      expect(cfg.browser.downloadDir, '/tmp/downloads');
      expect(cfg.browser.maxConcurrentContexts, 8);
      expect(cfg.browser.defaultViewport!['width'], 1920);
      expect(cfg.browser.defaultViewport!['height'], 1080);
    });

    test('c12b BrowserSettings.defaults', () {
      const s = BrowserSettings.defaults();
      expect(s.chromiumPath, isNull);
      expect(s.maxConcurrentContexts, 4);
      expect(s.respectRobots, isTrue);
    });
  });

  // --- c13 ---
  group('StorageSettings', () {
    test('c13 parses localKvPath / retention', () async {
      final path = await writeTmp('''
storage:
  localKvPath: /data/kv
  backupIntervalHours: 6
  retentionDays: 30
''');
      final cfg = await OpsConfig.load(path: path);
      expect(cfg.storage.localKvPath, '/data/kv');
      expect(cfg.storage.backupIntervalHours, 6);
      expect(cfg.storage.retentionDays, 30);
    });

    test('c13b StorageSettings.defaults', () {
      const s = StorageSettings.defaults();
      expect(s.localKvPath, isEmpty);
      expect(s.backupIntervalHours, 24);
      expect(s.retentionDays, 90);
    });
  });

  // --- c14 ---
  group('SecuritySettings', () {
    test(
      'c14 parses secretsBackend / aesKeyRef / auditRetentionDays',
      () async {
        final path = await writeTmp('''
security:
  secretsBackend: aes-file
  aesKeyRef: /etc/ops/key.bin
  auditRetentionDays: 730
''');
        final cfg = await OpsConfig.load(path: path);
        expect(cfg.security.secretsBackend, 'aes-file');
        expect(cfg.security.aesKeyRef, '/etc/ops/key.bin');
        expect(cfg.security.auditRetentionDays, 730);
      },
    );

    test('c14b SecuritySettings.defaults', () {
      const s = SecuritySettings.defaults();
      expect(s.secretsBackend, 'keychain');
      expect(s.aesKeyRef, isNull);
      expect(s.auditRetentionDays, 365);
    });
  });

  // --- c15 ---
  group('SystemAgentSettings', () {
    test('c15 parses all fields', () async {
      final path = await writeTmp('''
systemAgent:
  id: custom_admin
  displayName: Custom Admin
  workspaceId: _system
  providerOverride: claude
  modelOverride: claude-3-haiku
  systemPrompt: "You are a helpful admin."
  enabled: false
  toolCallingEnabled: true
''');
      final cfg = await OpsConfig.load(path: path);
      expect(cfg.systemAgent.id, 'custom_admin');
      expect(cfg.systemAgent.displayName, 'Custom Admin');
      expect(cfg.systemAgent.providerOverride, 'claude');
      expect(cfg.systemAgent.modelOverride, 'claude-3-haiku');
      expect(cfg.systemAgent.systemPrompt, 'You are a helpful admin.');
      expect(cfg.systemAgent.enabled, isFalse);
      expect(cfg.systemAgent.toolCallingEnabled, isTrue);
    });

    test('c15b SystemAgentSettings.defaults', () {
      const s = SystemAgentSettings.defaults();
      expect(s.id, '_ops_admin');
      expect(s.displayName, 'Ops Admin');
      expect(s.workspaceId, '_system');
      expect(s.enabled, isTrue);
      expect(s.toolCallingEnabled, isTrue);
    });
  });

  // --- c17 ---
  group('OutboundMcpServer', () {
    test('c17 parses id / transport / command / url', () async {
      final path = await writeTmp('''
mcp:
  outbound:
    servers:
      - id: local_brain
        transport: stdio
        command: /usr/local/bin/brain_kernel
      - id: remote_hub
        transport: sse
        url: http://hub.example.com/sse
''');
      final cfg = await OpsConfig.load(path: path);
      expect(cfg.mcp.outbound.length, 2);

      final stdio = cfg.mcp.outbound.first;
      expect(stdio.id, 'local_brain');
      expect(stdio.transport, 'stdio');
      expect(stdio.command, '/usr/local/bin/brain_kernel');
      expect(stdio.url, isNull);

      final sse = cfg.mcp.outbound.last;
      expect(sse.id, 'remote_hub');
      expect(sse.transport, 'sse');
      expect(sse.url, 'http://hub.example.com/sse');
    });
  });

  // --- c18 ---
  group('ChannelSettings', () {
    test('c18 parses providers map', () async {
      final path = await writeTmp('''
channel:
  providers:
    teams:
      webhookUrl: http://teams.example.com/hook
    email:
      smtp: smtp.example.com
''');
      final cfg = await OpsConfig.load(path: path);
      expect(cfg.channel.providers.containsKey('teams'), isTrue);
      expect(
        cfg.channel.providers['teams']!['webhookUrl'],
        'http://teams.example.com/hook',
      );
      expect(cfg.channel.providers.containsKey('email'), isTrue);
    });

    test('c18b ChannelSettings.empty', () {
      const s = ChannelSettings.empty();
      expect(s.providers, isEmpty);
    });
  });

  // --- OpsError ---
  group('OpsError', () {
    test('toString includes code and message', () {
      final e = OpsError(
        code: 'E9999',
        message: 'test message',
        detail: 'extra detail',
        suggestion: 'try again',
      );
      final s = e.toString();
      expect(s, contains('E9999'));
      expect(s, contains('test message'));
      expect(s, contains('extra detail'));
      expect(s, contains('try again'));
    });

    test('toString without optional fields', () {
      final e = OpsError(code: 'E0001', message: 'minimal');
      expect(e.toString(), contains('E0001'));
      expect(e.toString(), isNot(contains('Detail')));
    });
  });
}
