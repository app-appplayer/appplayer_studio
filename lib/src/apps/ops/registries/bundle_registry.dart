import 'dart:io';

import 'package:yaml/yaml.dart';

import 'workspace_registry.dart';

/// Local-filesystem bundle catalog.
///
/// Discovers directory-based bundles under [rootDir] (each with a
/// `manifest.yaml` matching `mcp_bundle` 's `BundleManifest`) and exposes
/// them to the app. Actual install-into-workspace lives in [BundleInstaller].
class BundleRegistry {
  BundleRegistry({this.rootDir = './bundles'});

  final String rootDir;
  final List<Bundle> _cache = [];
  bool _loaded = false;

  Future<List<Bundle>> list({WorkspaceType? filterType}) async {
    await _ensureLoaded();
    if (filterType == null) return List.unmodifiable(_cache);
    return _cache.where((b) => b.supports(filterType)).toList();
  }

  Future<Bundle?> get(String id) async {
    await _ensureLoaded();
    try {
      return _cache.firstWhere((b) => b.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Refresh from disk — e.g. after a user drops a new bundle in [rootDir].
  Future<void> reload() async {
    _cache.clear();
    _loaded = false;
    await _ensureLoaded();
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final root = Directory(rootDir);
    if (await root.exists()) {
      await for (final entry in root.list()) {
        if (entry is! Directory) continue;
        final manifestFile = File('${entry.path}/manifest.yaml');
        if (!await manifestFile.exists()) continue;
        try {
          final y = loadYaml(await manifestFile.readAsString());
          if (y is YamlMap) {
            _cache.add(
              Bundle._fromYaml(Map<String, dynamic>.from(y), entry.path),
            );
          }
        } catch (e) {
          stderr.writeln(
            'Bundle manifest load failed: ${manifestFile.path}: $e',
          );
        }
      }
    }
    _cache.sort((a, b) => a.id.compareTo(b.id));
    _loaded = true;
  }
}

/// In-memory view of a bundle on disk, matching the subset of
/// `BundleManifest` the app cares about during install.
class Bundle {
  Bundle._({
    required this.id,
    required this.name,
    required this.version,
    required this.type,
    required this.description,
    required this.provider,
    required this.capabilities,
    required this.dependencies,
    required this.targetWorkspaceType,
    required this.contents,
    required this.path,
    required this.author,
  });

  final String id;
  final String name;
  final String version;
  final String type; // application | library | skill | profile | extension
  final String description;
  final String provider;
  final List<String> capabilities;
  final List<String> dependencies;
  final String targetWorkspaceType; // org | personal | project | any
  /// Section name → relative directory (relative to bundle root).
  final Map<String, String> contents;
  final String path; // absolute bundle dir
  final String author;

  bool supports(WorkspaceType ws) =>
      targetWorkspaceType == 'any' || targetWorkspaceType == ws.name;

  static Bundle _fromYaml(Map<String, dynamic> y, String path) {
    final contentsRaw = y['contents'];
    final contents = <String, String>{};
    if (contentsRaw is YamlMap) {
      contentsRaw.forEach((k, v) {
        if (v is String) contents[k.toString()] = v;
      });
    } else if (contentsRaw is Map) {
      contentsRaw.forEach((k, v) {
        if (v is String) contents[k.toString()] = v;
      });
    }
    return Bundle._(
      id: y['id'] as String,
      name: (y['name'] as String?) ?? y['id'] as String,
      version: (y['version'] as String?) ?? '',
      type: (y['type'] as String?) ?? 'library',
      description: (y['description'] as String?) ?? '',
      provider: (y['provider'] as String?) ?? '',
      capabilities: (y['capabilities'] as List?)?.cast<String>() ?? const [],
      dependencies: (y['dependencies'] as List?)?.cast<String>() ?? const [],
      targetWorkspaceType: (y['targetWorkspaceType'] as String?) ?? 'any',
      contents: contents,
      path: path,
      author: (y['author'] as String?) ?? '',
    );
  }
}
