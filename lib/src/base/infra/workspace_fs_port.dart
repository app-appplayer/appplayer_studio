import 'dart:io';

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:brain_kernel/brain_kernel.dart'
    show
        BundleFolder,
        BundleStoragePort,
        McpBundle,
        McpBundleLoader,
        McpBundleWriter,
        McpLoaderOptions;
import 'package:path/path.dart' as p;

import '../types/builder_exceptions.dart';

/// On-disk gateway for the canonical `.mbd/` workspace.
///
/// All file I/O routes through mcp_bundle:
///   * Reads via [McpBundleLoader.loadDirectory] (manifest) plus
///     [McpBundle.uiResources] (raw `ui/<rel>.json` files).
///   * Writes via [McpBundleWriter.writeDirectory] (manifest + reserved
///     folders) wrapped in a temp-rename so the workspace is replaced
///     atomically.
///
/// Two surfaces are kept symmetric to match the reading layer:
///   * [writeAtomicJson] / [readJson] — raw map. Authoritative — round-trips
///     mcp_ui DSL ApplicationDefinition fields losslessly because the on-disk
///     `ui/app.json` is the source of truth, never funnelled through the
///     deprecated [UiSection] typed fields.
///   * [writeAtomic] / [read] — typed [McpBundle]. Convenience for consumers
///     that only need the manifest projection.
abstract interface class WorkspaceFsPort implements BundleStoragePort {
  Future<void> writeAtomic(McpBundle bundle, String workspacePath);
  Future<McpBundle?> read(String workspacePath);
  Future<void> writeAtomicJson(Map<String, dynamic> json, String workspacePath);
  Future<Map<String, dynamic>?> readJson(String workspacePath);
  Future<void> ensureDir(String workspacePath);

  /// True when [workspacePath] exists on the underlying storage. Used by
  /// the kernel canonical's draft-restore probe.
  Future<bool> dirExists(String workspacePath);

  /// Recursively delete [workspacePath]. No-op when absent. Used by the
  /// kernel canonical when purging a stale draft on commit / revert.
  Future<void> deleteDir(String workspacePath);
}

/// Disk-backed implementation. The on-disk layout matches the appplayer
/// canonical: `manifest.json` at root + `ui/app.json` (ApplicationDefinition)
/// + `ui/<id>.json` per page.
class FileWorkspaceFsPort implements WorkspaceFsPort {
  FileWorkspaceFsPort();

  @override
  Future<void> writeAtomic(McpBundle bundle, String workspacePath) =>
      writeAtomicJson(bundle.toJson(), workspacePath);

  @override
  Future<void> writeAtomicJson(
    Map<String, dynamic> json,
    String workspacePath,
  ) async {
    final target = Directory(workspacePath);
    final temp = Directory('$workspacePath.tmp');
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
    try {
      // Build the section payload for mcp_bundle's writer. The `ui` map
      // is split so each page is its own MCP resource, while templates
      // stay inline under `ui/app.json` so the AppPlayer runtime picks
      // them up via `ApplicationDefinition.templates` when it reads
      // `ui://app`:
      //   * `ui/app.json` — ApplicationDefinition body (everything
      //     except pages, including the inline `templates` map).
      //   * `ui/pages/<id>.json` — one file per page. Matches the
      //     appplayer URI resolver (`ui://pages/<id>` →
      //     `ui/pages/<id>.json`).
      final reserved = <BundleFolder, Map<String, Object>>{};
      final uiMap = json['ui'];
      if (uiMap is Map<String, dynamic>) {
        final pages = uiMap['pages'];
        final appJson = Map<String, dynamic>.of(uiMap)..remove('pages');
        final files = <String, Object>{
          if (appJson.isNotEmpty) 'app.json': appJson,
        };
        if (pages is Map) {
          pages.forEach((id, def) {
            if (def == null) return;
            files['pages/$id.json'] = def as Object;
          });
        }
        if (files.isNotEmpty) {
          reserved[BundleFolder.ui] = files;
        }
      }

      // The manifest written via mcp_bundle should not carry inline ui —
      // ui content lives under the ui/ reserved folder.
      final manifestJson = Map<String, dynamic>.from(json)..remove('ui');
      final McpBundle bundle;
      try {
        bundle = McpBundle.fromJson(manifestJson);
      } catch (e) {
        throw DiskException('McpBundle.fromJson failed: $e');
      }

      await McpBundleWriter.writeDirectory(
        bundle,
        temp.path,
        reservedFiles: reserved,
        overwrite: true,
      );

      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      await temp.rename(target.path);
    } catch (e) {
      if (await temp.exists()) {
        try {
          await temp.delete(recursive: true);
        } catch (_) {
          /* ignore cleanup failures */
        }
      }
      if (e is DiskException) rethrow;
      throw DiskException('writeAtomic failed: $e');
    }
  }

  @override
  Future<McpBundle?> read(String workspacePath) async {
    final dir = Directory(workspacePath);
    if (!await dir.exists()) return null;
    final manifestFile = File(p.join(workspacePath, 'manifest.json'));
    if (!await manifestFile.exists()) return null;
    try {
      return await McpBundleLoader.loadDirectory(
        workspacePath,
        options: const McpLoaderOptions.lenient(),
      );
    } catch (e) {
      throw LoadException('failed to load bundle at $workspacePath: $e');
    }
  }

  @override
  Future<Map<String, dynamic>?> readJson(String workspacePath) async {
    // `.mcpb` archive: extract to a temp directory and recurse on it.
    // mcp_bundle 0.3 does not expose a public archive loader; vibe
    // unpacks the zip itself rather than failing the import outright.
    final asFile = File(workspacePath);
    if (workspacePath.endsWith('.mcpb') && await asFile.exists()) {
      final temp = await _unpackMcpb(asFile);
      try {
        return await readJson(temp.path);
      } finally {
        try {
          await temp.delete(recursive: true);
        } catch (_) {
          /* best-effort cleanup */
        }
      }
    }

    final dir = Directory(workspacePath);
    if (!await dir.exists()) return null;
    final manifestFile = File(p.join(workspacePath, 'manifest.json'));
    if (!await manifestFile.exists()) return null;
    final McpBundle bundle;
    try {
      bundle = await McpBundleLoader.loadDirectory(
        workspacePath,
        options: const McpLoaderOptions.lenient(),
      );
    } catch (e) {
      throw LoadException('failed to load bundle at $workspacePath: $e');
    }

    final json = bundle.toJson();
    // The on-disk `ui/` folder is canonical. Override any inline ui block
    // a legacy manifest.json may have carried.
    final ui = await _readUiTree(bundle);
    if (ui != null) {
      json['ui'] = ui;
    } else {
      json.remove('ui');
    }
    return json;
  }

  /// Unzip [archive] into a fresh temporary directory and return it.
  /// Caller is responsible for deleting the directory after use.
  static Future<Directory> _unpackMcpb(File archive) async {
    final bytes = await archive.readAsBytes();
    final decoded = ZipDecoder().decodeBytes(bytes, verify: false);
    final temp = await Directory.systemTemp.createTemp('vibe_mcpb_');
    for (final entry in decoded) {
      final outPath = p.join(temp.path, entry.name);
      // Reject paths that escape the temp root (zip-slip defence).
      final normalized = p.normalize(outPath);
      if (!p.isWithin(temp.path, normalized) && normalized != temp.path) {
        continue;
      }
      if (entry.isFile) {
        final f = File(normalized);
        await f.parent.create(recursive: true);
        await f.writeAsBytes(entry.content as List<int>);
      } else {
        await Directory(normalized).create(recursive: true);
      }
    }
    return temp;
  }

  /// Read `ui/app.json` (ApplicationDefinition body, including the
  /// inline `templates` map) plus every `ui/pages/<id>.json` page file
  /// via [BundleResources]. Returns the assembled `ui` map, or null
  /// when the folder has no JSON content.
  ///
  /// Layout matches appplayer's URI resolver (`ui://pages/<id>` →
  /// `ui/pages/<id>.json`). Templates are not split into their own
  /// files because the AppPlayer runtime registers them from
  /// `ApplicationDefinition.templates` parsed off `ui://app`. Other
  /// top-level files under `ui/` (e.g. `ui/app/info.json`,
  /// host-specific extras) are ignored — only the canonical app + pages
  /// tree feeds the projection.
  static Future<Map<String, dynamic>?> _readUiTree(McpBundle bundle) async {
    if (bundle.directory == null) return null;
    final resources = bundle.uiResources;
    Map<String, dynamic>? ui;

    if (await resources.exists('app.json')) {
      try {
        final app = await resources.readJson('app.json');
        if (app is Map) {
          ui = Map<String, dynamic>.from(app);
        }
      } catch (e) {
        // Recover as missing (don't block the load), but surface the
        // corruption — a silent "malformed→empty ui" hides a real bug
        // behind a blank editor (parse-masking class).
        stderr.writeln(
          'workspace_fs_port: malformed app.json treated as '
          'missing ui: $e',
        );
      }
    }

    final pages = <String, dynamic>{};
    final files = await resources.list(extension: '.json');
    const pagesPrefix = 'pages/';
    for (final rel in files) {
      if (!rel.startsWith(pagesPrefix)) continue;
      final after = rel.substring(pagesPrefix.length);
      if (after.contains('/')) continue;
      if (!after.endsWith('.json')) continue;
      final id = after.substring(0, after.length - 5);
      try {
        final pageJson = await resources.readJson(rel);
        if (pageJson is Map) {
          pages[id] = Map<String, dynamic>.from(pageJson);
        }
      } catch (_) {
        /* skip malformed page file */
      }
    }
    if (pages.isNotEmpty) {
      ui ??= <String, dynamic>{};
      ui['pages'] = pages;
    }
    return ui;
  }

  @override
  Future<void> ensureDir(String workspacePath) async {
    await Directory(workspacePath).create(recursive: true);
  }

  @override
  Future<bool> dirExists(String workspacePath) =>
      Directory(workspacePath).exists();

  @override
  Future<void> deleteDir(String workspacePath) async {
    final dir = Directory(workspacePath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  // BundleStoragePort surface: vibe code talks to storage through the typed
  // methods above. The base port methods (load/save by URI, ...) are not
  // routed; consumers must use writeAtomic / read / writeAtomicJson /
  // readJson.
  @override
  noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
      'FileWorkspaceFsPort: BundleStoragePort method not routed (${invocation.memberName})',
    );
  }
}
