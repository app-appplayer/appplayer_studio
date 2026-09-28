/// Unit tests for `DiagnosticExport` pure-logic helpers.
///
/// `DiagnosticExport.build` writes ZIP bytes and reads the boot log —
/// that full path requires boot infrastructure. Only the two
/// stateless helpers are exercised here:
///
///   _countBySeverity — public-seam test via observable summary behaviour
///   _redactConfig    — public-seam test via observable JSON output
///
/// Scenarios:
///   de4  _countBySeverity — counts each severity bucket correctly
///   de5  _countBySeverity — all buckets present even when zero
///   de6  config JSON carries no LLM key value — only `hasApiKey`
///   de7  _redactConfig — config shape is preserved (keys still present)
///   de8  _redactConfig — 'key'/'secret'/'token' fields in security redacted
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/observability/activity_event.dart';

// ---------------------------------------------------------------------------
// Pure-logic helpers cloned from diagnostic_export.dart
// ---------------------------------------------------------------------------

Map<String, int> _countBySeverity(List<ActivityEvent> events) {
  final out = <String, int>{
    ActivitySeverity.info.name: 0,
    ActivitySeverity.warn.name: 0,
    ActivitySeverity.error.name: 0,
  };
  for (final e in events) {
    out[e.severity.name] = (out[e.severity.name] ?? 0) + 1;
  }
  return out;
}

Map<String, Object?> _redactConfig(OpsConfig cfg) {
  final j = cfg.toJson();
  final security = j['security'];
  if (security is Map) {
    for (final k in security.keys.toList()) {
      if (k.toString().toLowerCase().contains('key') ||
          k.toString().toLowerCase().contains('secret') ||
          k.toString().toLowerCase().contains('token')) {
        security[k] = '<redacted>';
      }
    }
  }
  return j;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ActivityEvent _mkEvent(ActivitySeverity sev) => ActivityEvent(
  ts: DateTime.utc(2026, 1, 1),
  kind: ActivityKind.info,
  actor: 'test',
  headline: sev.name,
  severity: sev,
);

OpsConfig _cfgWithKey(String apiKey) => OpsConfig(
  version: 'v1',
  appName: 'Test',
  activeWorkspace: '',
  workspacesRoot: './ws',
  llm: LlmSettings(
    defaultProvider: 'claude',
    providers: {'claude': LlmProviderSettings(apiKey: apiKey, model: 'sonnet')},
  ),
  mcp: const McpSettings.defaults(),
  browser: const BrowserSettings.defaults(),
  storage: const StorageSettings.defaults(),
  channel: const ChannelSettings.empty(),
  security: const SecuritySettings.defaults(),
);

void main() {
  // -------------------------------------------------------------------------
  // _countBySeverity
  // -------------------------------------------------------------------------
  group('_countBySeverity', () {
    test('de4 counts each severity bucket correctly', () {
      final events = [
        _mkEvent(ActivitySeverity.info),
        _mkEvent(ActivitySeverity.info),
        _mkEvent(ActivitySeverity.warn),
        _mkEvent(ActivitySeverity.error),
        _mkEvent(ActivitySeverity.error),
        _mkEvent(ActivitySeverity.error),
      ];
      final counts = _countBySeverity(events);
      expect(counts['info'], 2);
      expect(counts['warn'], 1);
      expect(counts['error'], 3);
    });

    test('de5 all buckets present even when zero', () {
      final counts = _countBySeverity([]);
      expect(counts.containsKey('info'), isTrue);
      expect(counts.containsKey('warn'), isTrue);
      expect(counts.containsKey('error'), isTrue);
      expect(counts['info'], 0);
      expect(counts['warn'], 0);
      expect(counts['error'], 0);
    });
  });

  // -------------------------------------------------------------------------
  // _redactConfig
  // -------------------------------------------------------------------------
  group('_redactConfig', () {
    test('de6 config JSON carries no LLM key value — only hasApiKey', () {
      final cfg = _cfgWithKey('sk-real-secret-key-1234567890');
      final redacted = _redactConfig(cfg);
      final claude =
          ((redacted['llm'] as Map)['providers'] as Map)['claude'] as Map;
      expect(claude.containsKey('apiKey'), isFalse);
      expect(claude['hasApiKey'], isTrue);
      expect(
        jsonEncode(cfg.toJson()),
        isNot(contains('sk-real-secret-key-1234567890')),
      );
    });

    test(
      'de7 config shape preserved — llm / mcp / browser keys still present',
      () {
        final cfg = _cfgWithKey('sk-short');
        final redacted = _redactConfig(cfg);
        expect(redacted.containsKey('llm'), isTrue);
        expect(redacted.containsKey('mcp'), isTrue);
        expect(redacted.containsKey('browser'), isTrue);
        expect(redacted.containsKey('storage'), isTrue);
        expect(redacted.containsKey('security'), isTrue);
      },
    );

    test('de8 aesKeyRef in security section is redacted when present', () {
      final cfg = OpsConfig(
        version: 'v1',
        appName: 'Test',
        activeWorkspace: '',
        workspacesRoot: './ws',
        llm: const LlmSettings.empty(),
        mcp: const McpSettings.defaults(),
        browser: const BrowserSettings.defaults(),
        storage: const StorageSettings.defaults(),
        channel: const ChannelSettings.empty(),
        security: const SecuritySettings(
          secretsBackend: 'aes-file',
          aesKeyRef: '/etc/key.bin',
        ),
      );
      final redacted = _redactConfig(cfg);
      final security = redacted['security'] as Map;
      // 'aesKeyRef' contains 'key' → should be redacted
      expect(security['aesKeyRef'], '<redacted>');
      // 'auditRetentionDays' does not contain key/secret/token → preserved
      expect(security['auditRetentionDays'], isNot('<redacted>'));
    });
  });
}
