/// Inheritance helpers for manifest-driven settings fields. The Domain
/// renderer (`_ManifestFieldList`-style host widget · `VbuSettingsSectionsForm`)
/// stays generic — it never references a parent scope by name. The host
/// (or any composer) calls [loadInheritedSettings] to snapshot the
/// studio-wide [VibeSettings] file, then [bakeInheritedFields] to pre-
/// substitute manifest field defaults so the renderer treats inherited
/// values as if the manifest had declared them.
///
/// Resolution chain rendered downstream:
///   per-package overrides JSON  >  baked field['value']
///                                  (= studio inherited > manifest default).
///
/// Editing a baked field writes to per-package overrides only — Studio's
/// global is never mutated by Domain edits.
import 'dart:convert';
import 'dart:io';

import 'vibe_settings.dart';

/// Snapshot the host-wide settings file (`~/.config/<toolId>/settings.json`)
/// as a flat `key → value` map. Exposes the system-wide keys every
/// domain settings surface inherits from by default — currently
/// `workspaceDir`, `mcpServerUrl`, `mcpTransport`. Missing file /
/// decode error → empty map so callers degrade gracefully.
/// Normalize a stored MCP server URL so the canonical Streamable HTTP
/// `/mcp` endpoint path is present. Settings written by older versions
/// (pre `/mcp` rollout) may lack the path; we append it on read so
/// system Settings + every domain that inherits show the full canonical
/// URL. Pool key consistency is enforced separately by
/// `DomainServerManager._normalizeUrl`.
String? _normalizeMcpUrl(String? raw) {
  if (raw == null || raw.isEmpty) return raw;
  final uri = Uri.tryParse(raw);
  if (uri == null) return raw;
  if (uri.path.isEmpty || uri.path == '/') {
    return uri.replace(path: '/mcp').toString();
  }
  return raw;
}

Map<String, Object?> loadInheritedSettings(String toolId) {
  try {
    final path = VibeSettings.defaultPath(toolId);
    final f = File(path);
    if (!f.existsSync()) return const <String, Object?>{};
    final decoded = jsonDecode(f.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      return const <String, Object?>{};
    }
    return <String, Object?>{
      'workspaceDir': decoded['workspaceDir'],
      'mcpServerUrl': _normalizeMcpUrl(decoded['mcpServerUrl'] as String?),
      'mcpTransport': decoded['mcpTransport'],
    };
  } catch (_) {
    return const <String, Object?>{};
  }
}

/// Build the **base "Domain MCP" section** every domain settings
/// surface gets for free, regardless of whether the domain's
/// `manifest.settings.sections` declares one. Three fields:
///
///   * `inheritFromSystem` (bool, default true) — when on, the domain
///     reuses the studio-wide MCP server; the URL / transport fields
///     below are inert. When off, the domain runs its own MCP server
///     instance using the URL / transport below.
///   * `mcpServerUrl` (text) — listen URL when not inheriting. Blank
///     = `DomainServerManager` auto-allocates a port (defaultPort+1
///     sweep).
///   * `mcpTransport` (enum http/sse) — transport when not inheriting.
///
/// The `inherited` map (snapshotted from system settings) supplies
/// the URL / transport defaults when present so the domain initially
/// shows the system values before the user overrides them.
///
/// Domain edits land in per-package overrides JSON, never in the
/// studio-wide settings file.
List<Map<String, dynamic>> buildBaseDomainFields(
  Map<String, Object?> inherited,
) {
  final urlDefault = (inherited['mcpServerUrl'] as String?) ?? '';
  final transportDefault = (inherited['mcpTransport'] as String?) ?? 'http';
  return <Map<String, dynamic>>[
    <String, dynamic>{
      'key': 'inheritFromSystem',
      'label': 'Inherit from Studio',
      'type': 'toggle',
      'value': true,
    },
    <String, dynamic>{
      'key': 'mcpServerUrl',
      'label': 'URL',
      'type': 'text',
      'value': urlDefault,
      'disabledWhen': 'inheritFromSystem',
      'disabledWhenValue': true,
    },
    <String, dynamic>{
      'key': 'mcpTransport',
      'label': 'Transport',
      'type': 'menu',
      'options': const <String>['http', 'sse'],
      'optionLabels': const <String, String>{
        'http': 'Streamable HTTP',
        'sse': 'SSE (legacy)',
      },
      'value': transportDefault,
      'disabledWhen': 'inheritFromSystem',
      'disabledWhenValue': true,
    },
  ];
}

/// Substitute `field['value']` with the inherited value when the manifest
/// declares no default (null / empty string) and the inherited map has
/// one. Override resolution (per-package JSON) still wins on top of this
/// — the inheritance just supplies a richer baseline.
List<Map<String, dynamic>> bakeInheritedFields(
  List<Map<String, dynamic>> fields,
  Map<String, Object?> inherited,
) {
  if (inherited.isEmpty) return fields;
  return <Map<String, dynamic>>[
    for (final f in fields)
      () {
        final key = f['key'];
        if (key is! String || !inherited.containsKey(key)) return f;
        final declared = f['value'];
        final hasDeclared =
            declared != null && !(declared is String && declared.isEmpty);
        if (hasDeclared) return f;
        final inheritedValue = inherited[key];
        if (inheritedValue == null) return f;
        return <String, dynamic>{...f, 'value': inheritedValue};
      }(),
  ];
}
