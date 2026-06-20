/// Host-side loader + accessor extension for activation-time bundle
/// reads. Replaces the former `bundle_manifest.dart` fork — the
/// canonical bundle types now live in `package:mcp_bundle`
/// (memory `feedback_bundle_no_fork_extend`). This file is the thin
/// host-shaped entry point: read the on-disk `.mbd/`, and surface the
/// few activation-time helpers the rest of the host depends on.
library;

import 'dart:convert';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:path/path.dart' as p;

/// Read `<mbdPath>/manifest.json` and return the parsed [mb.McpBundle]
/// with [mb.McpBundle.directory] set to the absolute mbd path. Returns
/// null when the manifest is missing, unreadable, or has no `id`.
///
/// The host activation pipeline calls this on package open. The
/// returned bundle carries every section the manifest declared
/// (`tools` / `requires` / `agents` / `ui` / ...) plus the directory
/// anchor used by [BundleHostAccessors.resolveAsset].
mb.McpBundle? readBundleAt(String mbdPath) {
  try {
    final file = File(p.join(mbdPath, 'manifest.json'));
    if (!file.existsSync()) return null;
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map<String, dynamic>) return null;
    // Tolerate the nested-`manifest` envelope (`{"manifest": {...}}`)
    // some bundles emit at the top level — McpBundle.fromJson expects
    // the canonical flat shape with a `manifest` key, which both forms
    // satisfy after this normalisation.
    final hasNestedManifest = raw['manifest'] is Map<String, dynamic>;
    final id =
        (hasNestedManifest
                ? (raw['manifest'] as Map<String, dynamic>)['id']
                : raw['id'])
            as String?;
    if (id == null || id.trim().isEmpty) return null;
    final json =
        hasNestedManifest
            ? raw
            : <String, dynamic>{
              ...raw,
              'manifest': <String, dynamic>{
                for (final k in const <String>[
                  'id',
                  'name',
                  'version',
                  'description',
                  'provider',
                  'icon',
                ])
                  if (raw[k] != null) k: raw[k],
              },
            };
    final root = Directory(mbdPath).absolute.path;
    return mb.McpBundle.fromJson(json).copyWith(directory: root);
  } catch (e) {
    // Unreadable / malformed bundle — return null (caller skips it), but
    // surface so a corrupt `.mbd` silently vanishing from the catalog is
    // diagnosable rather than a mystery (parse-masking class).
    stderr.writeln('bundle_loading: failed to load bundle at $mbdPath: $e');
    return null;
  }
}

/// Host-side helpers on [mb.McpBundle] that the activation pipeline +
/// chrome layer reach for. Kept as an extension so the canonical type
/// stays untouched while the host gets ergonomic accessors.
extension BundleHostAccessors on mb.McpBundle {
  /// Bundle id (`com.example.demo`).
  String get bundleId => manifest.id;

  /// Friendly display name when set, otherwise null. Use
  /// [displayLabel] for chrome rendering — it falls back to [shortId]
  /// when [bundleName] is empty.
  String? get bundleName {
    final n = manifest.name.trim();
    return n.isEmpty ? null : n;
  }

  /// Last dotted segment of [manifest.id] — `'demo_showcase'` from
  /// `'com.makemind.examples.demo_showcase'`. Used as the host-side
  /// MCP tool prefix base before disambiguation.
  String get shortId {
    final id = manifest.id;
    final dot = id.lastIndexOf('.');
    return dot >= 0 ? id.substring(dot + 1) : id;
  }

  /// Friendly label for chrome (tab strip, package picker). Resolves
  /// `manifest.name → shortId`.
  String get displayLabel => bundleName ?? shortId;

  /// Resolve [relativePath] against [mb.McpBundle.directory], returning
  /// an absolute path that is guaranteed to stay within the bundle —
  /// `..` segments that escape the install root cause a [StateError].
  /// Use for any asset reference declared in the manifest (tool
  /// entries, UI paths) so a malicious manifest can't reach the host
  /// filesystem.
  String resolveAsset(String relativePath) {
    final root = directory;
    if (root == null) {
      throw StateError(
        'McpBundle has no directory — load via readBundleAt before '
        'resolving assets',
      );
    }
    if (relativePath.isEmpty) {
      throw StateError('relativePath is empty');
    }
    if (p.isAbsolute(relativePath)) {
      throw StateError(
        'relativePath must be inside the bundle, got '
        'absolute path "$relativePath"',
      );
    }
    final joined = p.normalize(p.join(root, relativePath));
    final rootWithSep =
        root.endsWith(p.separator) ? root : '$root${p.separator}';
    if (joined != root && !joined.startsWith(rootWithSep)) {
      throw StateError(
        'relativePath "$relativePath" escapes install root "$root"',
      );
    }
    return joined;
  }

  /// Convenience: resolve a `kind: 'js'` tool's entry to an absolute
  /// path. Returns null when [tool] is not a JS tool or its entry is
  /// missing/empty (validator should have caught this; we handle it
  /// defensively so dispatch can surface a clear error).
  String? resolveJsEntry(mb.ToolEntry tool) {
    if (tool.kind != mb.ToolKind.js) return null;
    final target = tool.target;
    if (target is! Map) return null;
    final entry = target['entry'];
    if (entry is! String || entry.isEmpty) return null;
    return resolveAsset(entry);
  }

  /// Pull the host-shaped `ui` mount point out of the bundle's
  /// [mb.UiSection.raw] map. The bundle declares
  /// `{"kind": "mcp_ui_dsl"|"studio_ui", "path": "ui/app.json"}` under
  /// `ui:` in `manifest.json`; mcp_bundle's `UiSection` preserves it
  /// verbatim under [mb.UiSection.raw] so the host can read it without
  /// a typed schema slot. Returns null when no UI is declared.
  ///
  /// **Bundle-side follow-up candidate**: a typed `UiEntry` field on
  /// `UiSection` (or a new top-level slot) would replace this raw-map
  /// lookup if usage stays high. Tracked under
  /// `vibe-studio-bundle-uses-rollout`.
  UiEntryRef? get uiEntry {
    final raw = ui?.raw;
    if (raw == null) return null;
    final kind = raw['kind'];
    final path = raw['path'];
    if (kind is! String || kind.isEmpty) return null;
    if (path is! String || path.isEmpty) return null;
    if (kind != 'mcp_ui_dsl' && kind != 'studio_ui') return null;
    return UiEntryRef(kind: kind, path: path);
  }
}

/// Host-shaped UI mount point extracted from [mb.UiSection.raw].
/// Lives in the host (not mcp_bundle) until the canonical surface
/// gains a typed slot for this discriminator.
class UiEntryRef {
  const UiEntryRef({required this.kind, required this.path});

  /// `'mcp_ui_dsl'` (existing runtime) or `'studio_ui'` (workspace
  /// renderer planned in Phase 3).
  final String kind;

  /// Path inside the bundle to the UI entry — typically
  /// `'ui/app.json'` (mcp_ui_dsl) or a JS bundle entry (studio_ui).
  final String path;
}
