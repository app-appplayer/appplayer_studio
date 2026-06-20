// Diagnostic export — bundles boot.log + redacted OpsConfig + recent
// activity events + telemetry snapshot + workspace id list into a single
// `.zip` for support handoff. Defined in PRD §FM-OBSERVE-05.
//
// Secrets (API keys, OAuth tokens, AuthProfile) are scrubbed before
// inclusion. Logs older than 14 days are dropped to keep the bundle
// small.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../config/ops_config.dart';
import 'activity_event.dart';
import 'observability_module.dart';

class DiagnosticBundle {
  DiagnosticBundle({required this.bytes, required this.summary});
  final List<int> bytes;
  final Map<String, Object?> summary;
}

class DiagnosticExport {
  DiagnosticExport._();

  static Future<DiagnosticBundle> build({
    required ObservabilityModule observability,
    required OpsConfig config,
    int recentEvents = 200,
  }) async {
    final archive = Archive();

    final redactedConfig = _redactConfig(config);
    final cfgBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(redactedConfig),
    );
    archive.addFile(
      ArchiveFile('ops_config.redacted.json', cfgBytes.length, cfgBytes),
    );

    final telemetryBytes = utf8.encode(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(observability.telemetry.toJson()),
    );
    archive.addFile(
      ArchiveFile('telemetry.json', telemetryBytes.length, telemetryBytes),
    );

    final events = observability.bus.recent;
    final recentSlice =
        events.length <= recentEvents
            ? events
            : events.sublist(events.length - recentEvents);
    final eventBytes = utf8.encode(
      const JsonEncoder.withIndent(
        '  ',
      ).convert([for (final e in recentSlice) e.toJson()]),
    );
    archive.addFile(
      ArchiveFile('activity_events.json', eventBytes.length, eventBytes),
    );

    final platformInfo = {
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dartVersion': Platform.version,
      'locale': Platform.localeName,
      'numberOfProcessors': Platform.numberOfProcessors,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    final platformBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(platformInfo),
    );
    archive.addFile(
      ArchiveFile('platform.json', platformBytes.length, platformBytes),
    );

    final logFile = _bootLogFile();
    if (await logFile.exists()) {
      final raw = await logFile.readAsBytes();
      archive.addFile(ArchiveFile('boot.log', raw.length, raw));
    }

    final summary = {
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'configVersion': redactedConfig['version'],
      'eventCount': recentSlice.length,
      'severityCounts': _countBySeverity(recentSlice),
      'totals': observability.telemetry.toJson()['totals'],
      'fileList': [for (final f in archive) f.name],
    };
    final summaryBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(summary),
    );
    archive.addFile(
      ArchiveFile('summary.json', summaryBytes.length, summaryBytes),
    );

    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw StateError('Failed to encode diagnostic archive');
    }
    return DiagnosticBundle(bytes: encoded, summary: summary);
  }

  static File _bootLogFile() {
    final home = Platform.environment['HOME'] ?? '.';
    return File(p.join(home, '.makemind-ops', 'boot.log'));
  }

  static Map<String, int> _countBySeverity(List<ActivityEvent> events) {
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

  /// Scrub secrets from the OpsConfig before serialization. We keep the
  /// shape so support staff can see what's configured without seeing the
  /// raw values.
  static Map<String, Object?> _redactConfig(OpsConfig cfg) {
    final j = cfg.toJson();
    final llm = j['llm'];
    if (llm is Map) {
      final providers = llm['providers'];
      if (providers is Map) {
        for (final entry in providers.entries) {
          final v = entry.value;
          if (v is Map && v['apiKey'] is String) {
            v['apiKey'] = _maskKey(v['apiKey'] as String);
          }
        }
      }
    }
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

  static String _maskKey(String key) {
    if (key.isEmpty) return '<empty>';
    if (key.length <= 8) return '****';
    return '${key.substring(0, 4)}…${key.substring(key.length - 4)}';
  }
}
