/// KnowledgeSeedLoader — hands seed bundles to
/// `KnowledgeSystem.ops.loadBundle(...)`. Two kinds of seed:
///
///   - **base** — shipped with the host tool at `assets/seed/<id>.mbd/`.
///     Loaded once on first boot per install (marker file gates the
///     re-run; updating the bundle's manifest hash forces a refresh).
///   - **project** — the user's own `.mbd/`. Loaded on every project
///     open under the project's namespace so different projects keep
///     their domain knowledge isolated.
library;

import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' as fb;
import 'package:path/path.dart' as p;

class KnowledgeSeedLoader {
  KnowledgeSeedLoader({required this.system, required this.markerRoot});

  /// Target KnowledgeSystem (one global instance per host, via
  /// `FlowBrainWiring`).
  final fb.KnowledgeSystem system;

  /// Directory the loader writes its idempotency marker to. Typically
  /// `~/.config/<toolId>/`. The marker file `.seed_loaded.json`
  /// records `{loadedAt, sourceHash}` so a re-run with an unchanged
  /// bundle is a no-op.
  final String markerRoot;

  /// Load the base seed bundle once. Subsequent calls with the same
  /// `assetSeedPath` and unchanged manifest hash skip the reload.
  Future<bool> loadBaseSeedOnce(String assetSeedPath) async {
    final manifestFile = File(p.join(assetSeedPath, 'manifest.json'));
    if (!await manifestFile.exists()) {
      return false;
    }
    final manifestText = await manifestFile.readAsString();
    final manifest = jsonDecode(manifestText) as Map<String, dynamic>;
    final hash = _hashOf(manifestText);
    final markerFile = File(p.join(markerRoot, '.seed_loaded.json'));
    if (await markerFile.exists()) {
      try {
        final prev =
            jsonDecode(await markerFile.readAsString()) as Map<String, dynamic>;
        if (prev['sourceHash'] == hash) return false;
      } catch (_) {
        /* corrupt marker — fall through to re-load */
      }
    }
    final bundleId =
        manifest['id']?.toString() ??
        manifest['name']?.toString() ??
        'base-seed';
    await system.ops.loadBundle(bundleId, manifest);
    await markerFile.parent.create(recursive: true);
    await markerFile.writeAsString(
      jsonEncode(<String, dynamic>{
        'loadedAt': DateTime.now().toUtc().toIso8601String(),
        'sourceHash': hash,
        'bundleId': bundleId,
      }),
    );
    return true;
  }

  /// Load a project's `.mbd/` as a seed under the project's
  /// namespace. Idempotent within a process — the host typically
  /// drives this on every project open.
  Future<bool> loadProjectSeed(
    String mbdPath, {
    required String namespace,
  }) async {
    final manifestFile = File(p.join(mbdPath, 'manifest.json'));
    if (!await manifestFile.exists()) return false;
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    final bundleId =
        '$namespace:${manifest['id'] ?? manifest['name'] ?? 'project'}';
    await system.ops.loadBundle(bundleId, manifest);
    return true;
  }

  /// Drop the base-seed marker so the next call to [loadBaseSeedOnce]
  /// re-runs. Used by tests + dev "force reseed" flows.
  Future<void> clearBaseSeedMarker() async {
    final markerFile = File(p.join(markerRoot, '.seed_loaded.json'));
    if (await markerFile.exists()) await markerFile.delete();
  }

  /// Stable short hash of the manifest's serialized form. Cheap
  /// fingerprint — not crypto-grade — used only to detect "did the
  /// shipped seed bundle change?" between releases.
  String _hashOf(String s) {
    var h = 0;
    for (final code in s.codeUnits) {
      h = (h * 31 + code) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }
}
