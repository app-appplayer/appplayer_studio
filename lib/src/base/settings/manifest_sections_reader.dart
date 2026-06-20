/// Read a bundle's `manifest.settings.sections[]` and
/// `manifest.wiring.settings[]` and convert them to [SettingsSection]
/// instances every studio host can drop into the Settings dialog's
/// Domain panel.
///
/// Pure top-level helpers. The host owns:
///   * the `configRoot` where per-package override JSON is stored,
///   * the [ChromeBridge] for wiring-row tool dispatch,
///   * the `toolId` used to look up inherited studio-wide field values.
/// Base just does the manifest parse + section/widget composition.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../main/chrome_bridge.dart';
import '../widgets/editors/wiring_settings_list.dart';
import '../widgets/manifest_field_list.dart';
import 'manifest_field_inheritance.dart';
import 'settings_dialog.dart';

/// Resolve the per-package overrides file at
/// `<configRoot>/package_settings/<safeSlug>.json`. Caller may pass a
/// missing [configRoot] — file IO is lazy and best-effort.
String packageOverridesFile({
  required String? configRoot,
  required String pkgPath,
}) {
  final safe = pkgPath.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
  return p.join(configRoot ?? '/tmp', 'package_settings', '$safe.json');
}

/// Read `manifest.json` at the bundle's [mbdPath] and convert
/// `manifest.settings.sections[]` to read-only [SettingsSection]
/// widgets. Field values inherit from the studio-wide [VibeSettings]
/// snapshot keyed by [toolId]; per-package overrides land in the JSON
/// file resolved through [packageOverridesFile].
List<SettingsSection> readManifestSettingsSections(
  String mbdPath, {
  required String? configRoot,
  required String toolId,
  ChromeBridge? bridge,
}) {
  final inherited = loadInheritedSettings(toolId);
  final overridesFile = packageOverridesFile(
    configRoot: configRoot,
    pkgPath: mbdPath,
  );
  // Server-affecting keys — edits to any of these surface a
  // "Restart required" toast via ChromeBridge.notify. Keep tight: a
  // toast on every text-field keystroke is noisy.
  const serverKeys = <String>{
    'inheritFromSystem',
    'mcpServerUrl',
    'mcpTransport',
  };
  void notifyRestartIfServerKey(String key, Object? _) {
    if (!serverKeys.contains(key)) return;
    bridge?.notify?.call(
      'Restart required to apply MCP server changes.',
      severity: 'warning',
    );
  }

  // Base "Domain MCP" section — auto-prepended to every domain
  // settings surface regardless of whether the domain's
  // `manifest.settings.sections` declares one. Hosts the inheritance
  // toggle + per-domain MCP server URL / transport.
  final baseSection = SettingsSection(
    label: 'MCP server',
    body: ManifestFieldList(
      fields: buildBaseDomainFields(inherited),
      overridesFile: overridesFile,
      onFieldChanged: notifyRestartIfServerKey,
    ),
  );

  List<Map<String, dynamic>> domainSections = const <Map<String, dynamic>>[];
  try {
    final file = File(p.join(mbdPath, 'manifest.json'));
    if (file.existsSync()) {
      final raw = file.readAsStringSync();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      // settings is a top-level peer of the metadata wrapper per
      // mcp_bundle schema; fall back to wrapper-nested for legacy
      // manifests.
      Map<String, dynamic>? settings =
          json['settings'] as Map<String, dynamic>?;
      if (settings == null) {
        final wrapped = json['manifest'];
        if (wrapped is Map<String, dynamic>) {
          settings = wrapped['settings'] as Map<String, dynamic>?;
        }
      }
      domainSections =
          (settings?['sections'] as List<dynamic>? ?? const <dynamic>[])
              .whereType<Map<String, dynamic>>()
              .toList();
    }
  } catch (_) {
    // Manifest unreadable — domainSections stays empty; base section
    // still surfaces so the user has a place to flip inherit/standalone.
  }

  return <SettingsSection>[
    baseSection,
    for (final s in domainSections)
      SettingsSection(
        label: (s['label'] as String?) ?? 'section',
        body: ManifestFieldList(
          fields: bakeInheritedFields(
            (s['fields'] as List<dynamic>? ?? const <dynamic>[])
                .whereType<Map<String, dynamic>>()
                .toList(),
            inherited,
          ),
          overridesFile: overridesFile,
        ),
      ),
  ];
}

/// Read the bundle's `manifest.wiring.settings[]` at [mbdPath] and
/// convert it to a single "DOMAIN ACTIONS" [SettingsSection]. Each
/// entry renders as a tappable row (icon + label) that fires the bound
/// tool with the declared arguments through [bridge].dispatchBundleTool.
/// Returns an empty list when the bundle has no wiring.settings
/// entries — caller composes with other section sources.
List<SettingsSection> readWiringSettingsSections(
  String mbdPath, {
  required ChromeBridge bridge,
}) {
  try {
    final file = File(p.join(mbdPath, 'manifest.json'));
    if (!file.existsSync()) return const <SettingsSection>[];
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map<String, dynamic>) return const <SettingsSection>[];
    final wiring = raw['wiring'];
    if (wiring is! Map<String, dynamic>) return const <SettingsSection>[];
    final list = wiring['settings'];
    if (list is! List || list.isEmpty) return const <SettingsSection>[];
    final entries = <Map<String, dynamic>>[
      for (final e in list)
        if (e is Map<String, dynamic> &&
            e['tool'] is String &&
            (e['tool'] as String).isNotEmpty &&
            e['label'] is String &&
            (e['label'] as String).isNotEmpty)
          e,
    ];
    if (entries.isEmpty) return const <SettingsSection>[];
    return <SettingsSection>[
      SettingsSection(
        label: 'DOMAIN ACTIONS',
        body: WiringSettingsList(
          entries: entries,
          onFire: (toolShort, args) async {
            final fn = bridge.dispatchBundleTool;
            if (fn == null) return;
            try {
              await fn(mbdPath, toolShort, args);
            } catch (e) {
              bridge.notify?.call('$toolShort failed: $e', severity: 'error');
            }
          },
        ),
      ),
    ];
  } catch (_) {
    return const <SettingsSection>[];
  }
}
