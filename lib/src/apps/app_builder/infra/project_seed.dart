import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../core/vibe_project.dart' show ProjectKind;

/// Per-kind seed templates bundled as Flutter assets. Each template is
/// a flat list of asset paths whose file body is copied verbatim into
/// the new bundle, with `{{id}}` and `{{name}}` placeholders replaced
/// at copy time.
///
/// The asset prefix is the package-relative path the bundle uses. In the
/// open base (this package IS the host app) the assets resolve unprefixed —
/// `rootBundle.loadString('lib/src/.../seed/<file>')`. In an overlay tier
/// (e.g. pro: `appplayer_studio_pro` depends on `appplayer_studio`) Flutter
/// bundles the SAME assets under the cross-package indirection
/// `packages/appplayer_studio/<path>`, so the unprefixed key throws — see
/// [_loadSeedAsset]'s fallback. (Found live: pro-tier project creation died
/// mid-seed for every kind, leaving an empty bundle shell, 2026-07-13.)
const String _assetPrefix = 'lib/src/apps/app_builder/seed';

/// Cross-package asset prefix used when the host app is NOT this package
/// (overlay tiers). Must match this package's pub name.
const String _packageAssetPrefix = 'packages/appplayer_studio';

/// Load a seed asset that works in both tiers: try the unprefixed key
/// (open base = host app), fall back to the `packages/<pkg>/` key
/// (overlay host such as the pro tier).
Future<String> _loadSeedAsset(String assetPath) async {
  try {
    return await rootBundle.loadString(assetPath);
  } on Object {
    return rootBundle.loadString('$_packageAssetPrefix/$assetPath');
  }
}

const Map<ProjectKind, List<String>> _seedFilesByKind =
    <ProjectKind, List<String>>{
      ProjectKind.appPlayerApp: <String>[
        'manifest.json',
        'ui/app.json',
        'ui/pages/home.json',
      ],
      ProjectKind.studioPackage: <String>[
        'manifest.json',
        'ui/app.json',
        'ui/pages/home.json',
      ],
      // Cloud server app — normal bundle UI plus the tools/ directory
      // holding real TypeScript tool sources (SERVER_AUTHORING contract).
      ProjectKind.cloudServerApp: <String>[
        'manifest.json',
        'ui/app.json',
        'ui/pages/home.json',
        'tools/package.json',
        'tools/main.ts',
      ],
    };

String _assetDirFor(ProjectKind kind) {
  switch (kind) {
    case ProjectKind.appPlayerApp:
      return 'app_player_app';
    case ProjectKind.studioPackage:
      return 'studio_package';
    case ProjectKind.cloudServerApp:
      return 'cloud_server_app';
  }
}

/// Materialise the kind-specific seed into [bundleDir]. Idempotent —
/// files already present are overwritten so reseeding stays clean.
///
/// Placeholders:
///   `{{id}}`   → [projectName] (same value as `{{name}}` per the
///                 single-input new-project dialog).
///   `{{name}}` → [projectName].
///
/// Use as the `seedNewBundle` callback of `VibeProject.openAt`. The
/// canonical opens [bundleDir] right after this finishes, so the
/// initial in-memory state already carries the seed.
Future<void> applyProjectSeed(
  String bundleDir,
  ProjectKind kind,
  String projectName,
) async {
  final files = _seedFilesByKind[kind];
  if (files == null) return;
  final dir = _assetDirFor(kind);
  for (final relPath in files) {
    final assetPath = '$_assetPrefix/$dir/$relPath';
    final raw = await _loadSeedAsset(assetPath);
    final substituted = raw
        .replaceAll('{{id}}', projectName)
        .replaceAll('{{name}}', projectName);
    final target = File(p.join(bundleDir, relPath));
    await target.parent.create(recursive: true);
    await target.writeAsString(substituted);
  }
}
