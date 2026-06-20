import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../core/vibe_project.dart' show ProjectKind;

/// Per-kind seed templates bundled as Flutter assets. Each template is
/// a flat list of asset paths whose file body is copied verbatim into
/// the new bundle, with `{{id}}` and `{{name}}` placeholders replaced
/// at copy time.
///
/// The asset prefix is the package-relative path the bundle uses —
/// this app is the host's own package (single-package R26 layout), so
/// assets are listed directly in `pubspec.yaml`'s `flutter.assets`
/// block without the `packages/<other_pkg>/` indirection Flutter adds
/// for cross-package asset access. `rootBundle.loadString(<prefix>/<file>)`
/// resolves at runtime against the build's `flutter_assets/` tree.
const String _assetPrefix = 'lib/src/apps/app_builder/seed';

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
    };

String _assetDirFor(ProjectKind kind) {
  switch (kind) {
    case ProjectKind.appPlayerApp:
      return 'app_player_app';
    case ProjectKind.studioPackage:
      return 'studio_package';
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
    final raw = await rootBundle.loadString(assetPath);
    final substituted = raw
        .replaceAll('{{id}}', projectName)
        .replaceAll('{{name}}', projectName);
    final target = File(p.join(bundleDir, relPath));
    await target.parent.create(recursive: true);
    await target.writeAsString(substituted);
  }
}
