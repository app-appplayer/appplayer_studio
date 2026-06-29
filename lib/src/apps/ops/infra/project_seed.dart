import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

/// Asset prefix for the Ops project seed templates. Two artefacts:
///   - `project.opsproj`         — root project marker (id · name · createdAt)
///   - `project.mbd/manifest.json` — shared bundle (organization-wide
///     knowledge design, reused across every workspace)
///
/// The `project.mbd/` directory follows the canonical `mcp_bundle`
/// schema: a single `manifest.json` at the root with top-level
/// sections (`manifest`, `requires`, `agents`, `skills`, ...).
/// `brain_kernel`'s `BundleActivation` consumes the manifest verbatim
/// — no Ops-specific envelope.
///
/// `_system/` is reserved for system information / runtime caches
/// (config · auth · `ops.manager` agent KV) — a free-form directory the
/// registries write into on first use. It is intentionally NOT a
/// bundle: the shared `ops.manager` agent already ships from the seed
/// `makemind_ops.mbd` so every project reuses it without a
/// per-project bundle duplicate.
const String _assetPrefix = 'lib/src/apps/ops/seed/project';

/// Files copied verbatim into the project root. Each template carries
/// `{{id}}`, `{{name}}`, `{{createdAt}}` placeholders replaced at copy
/// time.
const List<String> _seedFiles = <String>[
  'project.opsproj',
  'project.mbd/manifest.json',
];

/// Root marker for an Ops project. Distinct from a `.mbd` bundle —
/// signals "this directory is an Ops project containing one or more
/// workspace bundles". Mirrors App Builder's `project.apbproj`.
const String opsProjectMarker = 'project.opsproj';

/// Materialise the Ops project skeleton into [projectDir]. Idempotent:
/// existing files are overwritten so re-seeding stays clean. Layout:
///
/// ```
/// <projectDir>/
///   project.opsproj           — root marker
///   project.mbd/manifest.json — shared bundle
///   _system/                  — free-form runtime dir (no manifest)
/// ```
Future<void> applyOpsProjectSeed(String projectDir, String projectName) async {
  final createdAt = DateTime.now().toUtc().toIso8601String();
  for (final rel in _seedFiles) {
    final raw = await rootBundle.loadString('$_assetPrefix/$rel');
    final substituted = raw
        .replaceAll('{{id}}', projectName)
        .replaceAll('{{name}}', projectName)
        .replaceAll('{{createdAt}}', createdAt);
    final target = File(p.join(projectDir, rel));
    await target.parent.create(recursive: true);
    await target.writeAsString(substituted);
  }
}

/// True when [projectDir] holds an Ops project — the root marker file
/// exists. Used by `_openProject` to refuse arbitrary directories.
bool isOpsProjectDir(String projectDir) {
  return File(p.join(projectDir, opsProjectMarker)).existsSync();
}

/// Asset path for the per-workspace manifest template. Stamped into
/// `<projectDir>/<wsId>.mbd/manifest.json` whenever the operator (or
/// MCP `workspace_create`) opens a new workspace inside the project.
const String _workspaceManifestAsset =
    'lib/src/apps/ops/seed/workspace/manifest.json';

/// Materialise a workspace-scoped `.mbd` bundle alongside the Ops
/// project. Each Ops workspace owns its own knowledge-design bundle
/// (agents / skills / profiles / philosophy / facts) — `BundleActivation`
/// activates this on the same boot path the shared `project.mbd` uses.
///
/// Layout:
/// ```
/// <projectDir>/<wsId>.mbd/manifest.json
/// ```
///
/// Idempotent — re-seeding overwrites the manifest so placeholder
/// changes propagate. Sibling operational-data sub-dirs (`members/`,
/// `tasks/`, ...) are created lazily by the workspace registries on
/// first write; this routine only seeds the bundle envelope.
Future<void> applyOpsWorkspaceSeed(
  String projectDir,
  String wsId,
  String wsName,
) async {
  final raw = await rootBundle.loadString(_workspaceManifestAsset);
  final substituted = raw
      .replaceAll('{{id}}', wsId)
      .replaceAll('{{name}}', wsName);
  // wsId may contain slashes (`WorkspaceRegistry` keys workspaces as
  // `'<type>/<slug>'`). Flatten the directory name so every workspace
  // bundle sits at the project root next to `project.mbd`, keeping the
  // BundleActivation scan single-layer.
  final mbdDirName = '${wsId.replaceAll('/', '_')}.mbd';
  final target = File(p.join(projectDir, mbdDirName, 'manifest.json'));
  await target.parent.create(recursive: true);
  await target.writeAsString(substituted);
}
