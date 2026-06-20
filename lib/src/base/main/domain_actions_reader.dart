/// Read `manifest.wiring.domainActions[]` and convert each entry into a
/// [HeaderAction]. Single source of truth for the binding pattern — host
/// shells call into this instead of hand-rolling their own readers (which
/// drift into hard-coded action lists). Same pattern as
/// `manifest_field_inheritance.dart` for settings.
///
/// Per-entry schema:
/// ```json
/// {
///   "tool":           "studio.renderer.activate",   // required
///   "args":           {"target": "ui"},              // default {}
///   "icon":           "preview",                     // friendly name
///   "tooltip":        "UI — live preview / canvas",
///   "divider":        true,                          // group boundary
///   "emphasisedWhen": {"key": "editorMode", "equals": "ui"}
/// }
/// ```
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../shell/project_header.dart';
import 'chrome_bridge.dart';

/// Parse `manifest.wiring.domainActions[]` at [mbdPath] and return a list
/// of [HeaderAction]s. Tap → [invokeTool] with the entry's `args` (or
/// `{}` when omitted). When the entry's `emphasisedWhen` references a
/// key present in [state], the action is emphasised iff the values match
/// — supports mode-toggle patterns (the same icon strip showing which
/// mode is currently active).
///
/// [exposedNs] is the activated bundle's MCP namespace; non-empty values
/// are prepended to each `tool` short name (`<exposedNs>.<tool>`). Tool
/// names that already contain a `.` pass through unchanged so host-level
/// tools (`studio.renderer.activate`, `studio.fs.read`) can be wired
/// directly.
List<HeaderAction> readDomainActionsFromManifest({
  required String mbdPath,
  required Future<void> Function(String fullToolName, Map<String, dynamic> args)
  invokeTool,
  String? exposedNs,
  ChromeBridge? bridge,
  Map<String, Object?> state = const <String, Object?>{},
}) {
  if (mbdPath.isEmpty) return const <HeaderAction>[];
  try {
    final file = File(p.join(mbdPath, 'manifest.json'));
    if (!file.existsSync()) return const <HeaderAction>[];
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map<String, dynamic>) return const <HeaderAction>[];
    final wiring = raw['wiring'];
    if (wiring is! Map<String, dynamic>) return const <HeaderAction>[];
    final list = wiring['domainActions'];
    if (list is! List) return const <HeaderAction>[];
    final out = <HeaderAction>[];
    for (final entry in list) {
      if (entry is! Map<String, dynamic>) continue;
      final kind = entry['kind']?.toString();
      if (kind == 'selectGroup') {
        // Group affordance — N icons sharing one runtime state key;
        // the item whose `value` matches gets mint emphasis. See
        // `tools/builder/docs/studio-builder-runtime-model.md` §8.1.b.
        _appendSelectGroup(
          entry: entry,
          state: state,
          exposedNs: exposedNs,
          invokeTool: invokeTool,
          bridge: bridge,
          out: out,
        );
        continue;
      }
      // Default: single-button affordance. `kind` may be omitted (legacy)
      // or set explicitly to "button". `emphasisedWhen` (legacy) still
      // honoured so existing bundles keep working — recommended for new
      // bundles to migrate to `kind: "selectGroup"`.
      _appendButton(
        entry: entry,
        state: state,
        exposedNs: exposedNs,
        invokeTool: invokeTool,
        bridge: bridge,
        out: out,
      );
    }
    return out;
  } catch (_) {
    return const <HeaderAction>[];
  }
}

void _appendButton({
  required Map<String, dynamic> entry,
  required Map<String, Object?> state,
  required String? exposedNs,
  required Future<void> Function(String, Map<String, dynamic>) invokeTool,
  required ChromeBridge? bridge,
  required List<HeaderAction> out,
}) {
  final toolShort = entry['tool']?.toString();
  if (toolShort == null || toolShort.isEmpty) return;
  final iconName = entry['icon']?.toString() ?? 'extension';
  final label = entry['tooltip']?.toString() ?? '$toolShort (domain action)';
  final fullName = _resolveFullToolName(toolShort, exposedNs);
  final tooltip = '$label\ntool: $toolShort\nid: $fullName';
  final args = _readArgs(entry);
  final hasExplicitDivider = entry['divider'] == true;
  var emphasised = false;
  // Legacy `emphasisedWhen` — kept so existing manifests keep
  // emphasising correctly during migration to `kind: "selectGroup"`.
  final eW = entry['emphasisedWhen'];
  if (eW is Map<String, dynamic>) {
    final key = eW['key']?.toString();
    if (key != null) {
      final got = _lookupDotPath(state, key);
      if (got != null) emphasised = got == eW['equals'];
    }
  }
  out.add(
    HeaderAction(
      tooltip: tooltip,
      icon: materialIconByName(iconName),
      divider: hasExplicitDivider,
      emphasised: emphasised,
      elementId: toolShort,
      onTap: () async {
        try {
          await invokeTool(fullName, args);
        } catch (e) {
          bridge?.notify?.call('$toolShort failed: $e', severity: 'error');
        }
      },
    ),
  );
}

void _appendSelectGroup({
  required Map<String, dynamic> entry,
  required Map<String, Object?> state,
  required String? exposedNs,
  required Future<void> Function(String, Map<String, dynamic>) invokeTool,
  required ChromeBridge? bridge,
  required List<HeaderAction> out,
}) {
  final stateKey = entry['stateKey']?.toString();
  final rawItems = entry['items'];
  if (stateKey == null || stateKey.isEmpty || rawItems is! List) return;
  final activeValue = _lookupDotPath(state, stateKey);
  for (final raw in rawItems) {
    if (raw is! Map<String, dynamic>) continue;
    final toolShort = raw['tool']?.toString();
    if (toolShort == null || toolShort.isEmpty) continue;
    final iconName = raw['icon']?.toString() ?? 'extension';
    final label = raw['tooltip']?.toString() ?? toolShort;
    final fullName = _resolveFullToolName(toolShort, exposedNs);
    final tooltip = '$label\ntool: $toolShort\nid: $fullName';
    final args = _readArgs(raw);
    final value = raw['value'];
    final emphasised = activeValue != null && activeValue == value;
    // SelectGroup item element id — prefer the explicit value (e.g.
    // "/ui") for nav strips since it identifies the route the icon
    // toggles; fall back to the tool short name.
    final itemElementId =
        value is String && value.isNotEmpty ? value : toolShort;
    out.add(
      HeaderAction(
        tooltip: tooltip,
        icon: materialIconByName(iconName),
        // Group items don't draw a divider between themselves —
        // chrome may use the group continuity as a visual hint.
        divider: false,
        emphasised: emphasised,
        elementId: itemElementId,
        onTap: () async {
          try {
            await invokeTool(fullName, args);
          } catch (e) {
            bridge?.notify?.call('$toolShort failed: $e', severity: 'error');
          }
        },
      ),
    );
  }
}

String _resolveFullToolName(String toolShort, String? exposedNs) {
  if (exposedNs == null || exposedNs.isEmpty || toolShort.contains('.')) {
    return toolShort;
  }
  return '$exposedNs.$toolShort';
}

Map<String, dynamic> _readArgs(Map<String, dynamic> entry) {
  // `args` is the canonical key; `arguments` accepted as legacy alias.
  final a = entry['args'] ?? entry['arguments'];
  if (a is Map) return Map<String, dynamic>.from(a);
  return const <String, dynamic>{};
}

/// Resolve a dot-separated path like `runtime.navigation.currentRoute`
/// against a top-level map. Returns null when any segment is missing
/// or a non-map is encountered mid-path. Same lookup convention the
/// flutter_mcp_ui_runtime spec uses for its state binding paths.
Object? _lookupDotPath(Map<String, Object?> state, String path) {
  Object? cursor = state;
  for (final part in path.split('.')) {
    if (cursor is Map) {
      cursor = cursor[part];
    } else {
      return null;
    }
    if (cursor == null) return null;
  }
  return cursor;
}

/// Friendly icon name → [IconData] map. Bundles declare names in
/// `manifest.wiring.domainActions[].icon`; unknown names fall back to
/// `extension` so the icon still shows (and the author sees that the
/// declared name didn't resolve). Kept as a small whitelist so hosts can
/// audit the affordance surface without exposing the full Material
/// catalog to authoring tools.
IconData materialIconByName(String name) {
  const m = <String, IconData>{
    'extension': Icons.extension_outlined,
    'play': Icons.play_arrow_outlined,
    'stop': Icons.stop_outlined,
    'refresh': Icons.refresh,
    'add': Icons.add,
    'delete': Icons.delete_outlined,
    'edit': Icons.edit_outlined,
    'save': Icons.save_outlined,
    'search': Icons.search,
    'filter': Icons.filter_alt_outlined,
    'history': Icons.history,
    'star': Icons.star_outline,
    'flag': Icons.flag_outlined,
    'bug': Icons.bug_report_outlined,
    'check': Icons.check,
    'sync': Icons.sync,
    'cloud': Icons.cloud_outlined,
    'database': Icons.storage_outlined,
    'terminal': Icons.terminal,
    'graph': Icons.account_tree_outlined,
    'chart': Icons.bar_chart_outlined,
    'table': Icons.table_rows_outlined,
    'mail': Icons.mail_outlined,
    'send': Icons.send_outlined,
    'lock': Icons.lock_outline,
    'unlock': Icons.lock_open_outlined,
    'key': Icons.key_outlined,
    'shield': Icons.shield_outlined,
    'palette': Icons.palette_outlined,
    'image': Icons.image_outlined,
    'audio': Icons.music_note_outlined,
    'video': Icons.video_library_outlined,
    'file': Icons.insert_drive_file_outlined,
    'folder': Icons.folder_outlined,
    'link': Icons.link,
    'share': Icons.share_outlined,
    'export': Icons.file_upload,
    'import': Icons.file_download,
    'tune': Icons.tune,
    // Mode-toggle icons (UI / Tools / Knowledge / Manifest).
    'preview': Icons.preview_outlined,
    'build': Icons.build_outlined,
    'school': Icons.school_outlined,
    'description': Icons.description_outlined,
    // Built-in app launcher icons.
    'dashboard': Icons.dashboard_outlined,
    'business': Icons.business_outlined,
    'business_center': Icons.business_center_outlined,
    'group': Icons.group_outlined,
    'psychology': Icons.psychology_outlined,
  };
  return m[name] ?? Icons.extension_outlined;
}
