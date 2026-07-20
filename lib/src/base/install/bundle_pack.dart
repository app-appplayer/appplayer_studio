/// Distribution packing — canonical `.mcpb` bytes for a bundle dir,
/// EXCLUDING authoring metadata.
///
/// A live authoring bundle carries workspace-only entries — `.history/`
/// (per-edit snapshots), `.DS_Store`, other dot-files — that must never
/// ship in a distributed archive. Beyond the size/leak concern this is
/// load-bearing: `.history/<ts>/ui/pages/<id>.json` snapshots are OLD
/// copies of real resources, and a consumer that resolves `ui://pages/<id>`
/// by a loose path match (e.g. the marketplace serving shell's
/// `(?:^|\/)ui\/pages\/...` entry regex) can pick the STALE snapshot over
/// the live page — found live 2026-07-13: a cloud server app served its
/// pre-edit home page (button-less) because `.history` shipped inside the
/// packed bundle.
///
/// Packing still goes through [McpBundlePacker] (integrity block, entry
/// ordering); the exclusion happens by packing a filtered temp copy.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:mcp_bundle/mcp_bundle.dart' show McpBundlePacker;
import 'package:path/path.dart' as p;

/// True when any path segment of [relPath] starts with a dot —
/// authoring/OS metadata that must not ship.
bool isAuthoringMetadataPath(String relPath) =>
    p.split(relPath).any((seg) => seg.startsWith('.'));

/// Pack [bundleDir] into canonical `.mcpb` bytes, excluding every entry
/// whose path contains a dot-segment (`.history/`, `.DS_Store`, …).
Future<Uint8List> packBundleDirForDistribution(String bundleDir) async {
  final src = Directory(bundleDir);
  final temp = await Directory.systemTemp.createTemp('vibe_pack_clean_');
  try {
    await for (final entity in src.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: bundleDir);
      if (isAuthoringMetadataPath(rel)) continue;
      final dest = File(p.join(temp.path, rel));
      await dest.parent.create(recursive: true);
      await entity.copy(dest.path);
    }
    final bytes = await McpBundlePacker.packDirectory(temp.path);
    return Uint8List.fromList(bytes);
  } finally {
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      /* best-effort temp cleanup */
    }
  }
}
