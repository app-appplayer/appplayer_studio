/// `BundleInstallSurface` — knowledge bundle install / list / uninstall
/// + BM25 query helper, factored out of every host so the same wiring
/// powers Settings dialogs, MCP tool handlers, and panel UIs.
///
/// Two acceptance modes:
///   * `.mcpb` archive (zip) — unpacked under
///     `<configRoot>/installed/<basename>/` then registered.
///   * `.mbd/` directory — registered in place (no copy).
///
/// Returns plain JSON-shaped `Map<String, dynamic>` so callers (Settings
/// UI, MCP tool result envelopes, ServerBridge callbacks) round-trip
/// without per-host serialisation. The error envelope is always
/// `{ok: false, error: '<msg>'}` — successful install adds
/// `{ok: true, namespace, mbdPath}`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:path/path.dart' as p;

class BundleInstallSurface {
  BundleInstallSurface({
    required this.bundleRegistry,
    required this.knowledgeEngine,
    required this.installedCacheDir,
  });

  final mk.KnowledgeBundleRegistry bundleRegistry;
  final mk.KnowledgeQueryEngine knowledgeEngine;
  final String installedCacheDir;

  /// Install a bundle from [sourcePath] (`.mcpb` zip or `.mbd` dir).
  /// Idempotent — re-installing the same source path overwrites the
  /// previous extraction (zip) or refreshes the registry entry (dir).
  Future<Map<String, dynamic>> install(String sourcePath) async {
    try {
      String registerPath;
      String fallbackBasename;
      final type = await FileSystemEntity.type(sourcePath);
      if (type == FileSystemEntityType.notFound) {
        return <String, dynamic>{
          'ok': false,
          'error': 'path not found: $sourcePath',
        };
      }
      if (type == FileSystemEntityType.directory) {
        registerPath = Directory(sourcePath).absolute.path;
        fallbackBasename = p.basename(p.normalize(sourcePath));
      } else {
        final ext = p.extension(sourcePath).toLowerCase();
        if (ext != '.mcpb') {
          return <String, dynamic>{
            'ok': false,
            'error':
                'expected a .mcpb file or .mbd/ directory '
                '(got "$ext" file)',
          };
        }
        final mcpbFile = File(sourcePath);
        fallbackBasename = p.basenameWithoutExtension(sourcePath);
        final extractDir = Directory(
          p.join(installedCacheDir, fallbackBasename),
        );
        if (await extractDir.exists()) {
          await extractDir.delete(recursive: true);
        }
        await extractDir.create(recursive: true);
        final bytes = await mcpbFile.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final f in archive.files) {
          final outPath = p.join(extractDir.path, f.name);
          if (f.isFile) {
            final out = File(outPath);
            await out.parent.create(recursive: true);
            await out.writeAsBytes(f.content as List<int>);
          } else {
            await Directory(outPath).create(recursive: true);
          }
        }
        registerPath = extractDir.absolute.path;
      }
      final manifestFile = File(p.join(registerPath, 'manifest.json'));
      if (!await manifestFile.exists()) {
        return <String, dynamic>{
          'ok': false,
          'error': 'manifest.json not found in $registerPath',
        };
      }
      final manifestRaw = await manifestFile.readAsString();
      final json = jsonDecode(manifestRaw) as Map<String, dynamic>;
      final manifestSection = json['manifest'] as Map<String, dynamic>?;
      final namespace =
          (manifestSection?['id'] as String?) ??
          (json['id'] as String?) ??
          fallbackBasename;
      await bundleRegistry.upsert(mbdPath: registerPath, namespace: namespace);
      knowledgeEngine.invalidate();
      return <String, dynamic>{
        'ok': true,
        'namespace': namespace,
        'mbdPath': registerPath,
      };
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': '$e'};
    }
  }

  /// Snapshot of the registry as JSON entries. Order matches the
  /// underlying registry — typically install time.
  Future<List<Map<String, dynamic>>> list() async {
    final entries = await bundleRegistry.list();
    return <Map<String, dynamic>>[for (final e in entries) e.toJson()];
  }

  /// Remove a bundle by `mbdPath`. Returns
  /// `{ok: true, removed: true, deletedCache: bool}` when the entry
  /// existed, `{ok: true, removed: false}` when there was nothing to
  /// drop. When [mbdPath] lives inside [installedCacheDir] (i.e. the
  /// host extracted it from a `.mcpb` archive) the extracted directory
  /// is also deleted — user-owned `.mbd/` directories outside the
  /// cache root stay on disk untouched.
  Future<Map<String, dynamic>> uninstall(String mbdPath) async {
    try {
      final removed = await bundleRegistry.remove(mbdPath);
      if (!removed) {
        return <String, dynamic>{'ok': true, 'removed': false};
      }
      knowledgeEngine.invalidate();
      var deletedCache = false;
      final cacheRoot = Directory(installedCacheDir).absolute.path;
      final target = Directory(mbdPath).absolute.path;
      if (p.isWithin(cacheRoot, target)) {
        final dir = Directory(mbdPath);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
          deletedCache = true;
        }
      }
      return <String, dynamic>{
        'ok': true,
        'removed': true,
        'deletedCache': deletedCache,
      };
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': '$e'};
    }
  }

  /// BM25 zero-LLM query across installed bundles. [topK] caps the
  /// number of hits; [namespace] / [sourceId] narrow the search to a
  /// specific bundle / source. Empty input yields an empty list.
  Future<List<Map<String, dynamic>>> query(
    String text, {
    int topK = 5,
    String? namespace,
    String? sourceId,
  }) async {
    final hits = await knowledgeEngine.query(
      text,
      topK: topK,
      namespace: namespace,
      sourceId: sourceId,
    );
    return <Map<String, dynamic>>[for (final h in hits) h.toJson()];
  }
}
