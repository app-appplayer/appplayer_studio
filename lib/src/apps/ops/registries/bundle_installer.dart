import 'dart:io';

import 'package:yaml/yaml.dart';

import '../infra/ws_paths.dart';
import '../util/atomic_write.dart';
import '../skills/skill_definition.dart';
import '../skills/skill_registry.dart';
import 'bundle_registry.dart';

/// Installs [Bundle] sources into a workspace directory.
///
/// The install model:
///   - For each declared `contents` section, copy the bundle's subdirectory
///     into the matching workspace subdirectory (files overwrite within the
///     same bundle's section, but files belonging to other installed bundles
///     are left alone — conflict detection uses file name).
///   - Append an entry to `workspaces/<id>/installed_bundles.yaml` with the
///     bundle id · version · installedAt · copied file list (for uninstall).
///   - Rescan skill YAMLs in the workspace and register them into the
///     live [AppSkillRegistry] so new capabilities become callable
///     immediately.
class BundleInstaller {
  BundleInstaller({required this.workspacesRoot, this.appSkills});

  final String workspacesRoot;

  /// May be null during first-run (before the engine boots) — in that case
  /// skill live-registration is deferred to the next app launch's
  /// [WorkspaceLoader] pass.
  final AppSkillRegistry? appSkills;

  Future<InstallationRecord> install({
    required Bundle bundle,
    required String workspaceId,
  }) async {
    final wsRoot = wsContentRoot(workspacesRoot, workspaceId);
    final wsDir = Directory(wsRoot);
    if (!await wsDir.exists()) {
      throw StateError('Workspace dir missing: $wsRoot');
    }

    final copied = <String>[];
    final conflicts = <String>[];

    for (final entry in bundle.contents.entries) {
      final section = entry.key;
      final relDir = entry.value;
      final srcDir = Directory(_joinPaths(bundle.path, relDir));
      if (!await srcDir.exists()) continue;
      final dstDir = Directory('$wsRoot/$section');
      await dstDir.create(recursive: true);
      await for (final fse in srcDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (fse is! File) continue;
        final rel = fse.path
            .substring(srcDir.path.length)
            .replaceFirst(RegExp(r'^/'), '');
        final target = File('${dstDir.path}/$rel');
        // Preserve the user's existing file when names collide. The
        // conflict is recorded so the UI can prompt for a manual merge,
        // and the workspace copy is left untouched.
        if (await target.exists()) {
          conflicts.add('$section/$rel');
          continue;
        }
        await target.parent.create(recursive: true);
        await fse.copy(target.path);
        copied.add('$section/$rel');
      }
    }

    final record = InstallationRecord(
      bundleId: bundle.id,
      version: bundle.version,
      installedAt: DateTime.now(),
      copied: copied,
      conflicts: conflicts,
    );
    await _appendRecord(wsRoot, record);

    // Live-register any skills that arrived with this install.
    await _reloadWorkspaceSkills(wsRoot);
    return record;
  }

  Future<List<InstallationRecord>> listInstalled(String workspaceId) async {
    final wsRoot = wsContentRoot(workspacesRoot, workspaceId);
    final file = File('$wsRoot/installed_bundles.yaml');
    if (!await file.exists()) return const [];
    final y = loadYaml(await file.readAsString());
    if (y is! YamlMap) return const [];
    final installs = y['installs'];
    if (installs is! YamlList) return const [];
    return installs
        .whereType<YamlMap>()
        .map(
          (m) => InstallationRecord(
            bundleId: m['bundleId'] as String,
            version: (m['version'] as String?) ?? '',
            installedAt:
                DateTime.tryParse(m['installedAt'] as String? ?? '') ??
                DateTime.now(),
            copied:
                (m['copied'] as YamlList?)?.cast<String>().toList() ?? const [],
            conflicts:
                (m['conflicts'] as YamlList?)?.cast<String>().toList() ??
                const [],
          ),
        )
        .toList();
  }

  Future<void> uninstall({
    required String bundleId,
    required String workspaceId,
  }) async {
    final wsRoot = wsContentRoot(workspacesRoot, workspaceId);
    final installs = await listInstalled(workspaceId);
    final target = installs.where((r) => r.bundleId == bundleId).toList();
    if (target.isEmpty) return;

    for (final rec in target) {
      for (final rel in rec.copied) {
        final f = File('$wsRoot/$rel');
        if (await f.exists()) {
          // Only delete if another installed bundle hasn't claimed the same
          // path via overwrite.
          final stillOwnedByOther = installs.any(
            (o) => o.bundleId != bundleId && o.copied.contains(rel),
          );
          if (!stillOwnedByOther) {
            await f.delete();
          }
        }
      }
    }
    // Write a new installed_bundles.yaml minus the uninstalled entries.
    final remaining = installs.where((r) => r.bundleId != bundleId).toList();
    await _writeInstalls(wsRoot, remaining);
    await _reloadWorkspaceSkills(wsRoot);
  }

  Future<void> _appendRecord(String wsRoot, InstallationRecord rec) async {
    final existing = await _loadInstalls(wsRoot);
    existing.removeWhere((r) => r.bundleId == rec.bundleId);
    existing.add(rec);
    await _writeInstalls(wsRoot, existing);
  }

  Future<List<InstallationRecord>> _loadInstalls(String wsRoot) async {
    final file = File('$wsRoot/installed_bundles.yaml');
    if (!await file.exists()) return <InstallationRecord>[];
    final y = loadYaml(await file.readAsString());
    if (y is! YamlMap) return <InstallationRecord>[];
    final installs = y['installs'];
    if (installs is! YamlList) return <InstallationRecord>[];
    return installs
        .whereType<YamlMap>()
        .map(
          (m) => InstallationRecord(
            bundleId: m['bundleId'] as String,
            version: (m['version'] as String?) ?? '',
            installedAt:
                DateTime.tryParse(m['installedAt'] as String? ?? '') ??
                DateTime.now(),
            copied:
                (m['copied'] as YamlList?)?.cast<String>().toList() ?? const [],
            conflicts:
                (m['conflicts'] as YamlList?)?.cast<String>().toList() ??
                const [],
          ),
        )
        .toList();
  }

  Future<void> _writeInstalls(
    String wsRoot,
    List<InstallationRecord> installs,
  ) async {
    final file = File('$wsRoot/installed_bundles.yaml');
    final buf = StringBuffer();
    buf.writeln('installs:');
    for (final r in installs) {
      buf.writeln('  - bundleId: ${r.bundleId}');
      buf.writeln('    version: "${r.version}"');
      buf.writeln('    installedAt: ${r.installedAt.toIso8601String()}');
      buf.writeln('    copied:');
      for (final c in r.copied) buf.writeln('      - "$c"');
      if (r.conflicts.isNotEmpty) {
        buf.writeln('    conflicts:');
        for (final c in r.conflicts) buf.writeln('      - "$c"');
      }
    }
    await writeStringAtomic(file, buf.toString());
  }

  Future<void> _reloadWorkspaceSkills(String wsRoot) async {
    final registry = appSkills;
    if (registry == null) return; // first-run path: defer until next boot.
    final dir = Directory('$wsRoot/skills');
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.yaml') && !entity.path.endsWith('.yml')) {
        continue;
      }
      try {
        final raw = await entity.readAsString();
        final yaml = loadYaml(raw);
        if (yaml is YamlMap) {
          final def = SkillDefinition.fromYaml(Map<String, dynamic>.from(yaml));
          registry.register(def);
        }
      } catch (e) {
        stderr.writeln('Skill reload failed: ${entity.path}: $e');
      }
    }
  }

  String _joinPaths(String a, String b) {
    var left = a;
    var right = b;
    if (right.startsWith('./')) right = right.substring(2);
    if (left.endsWith('/')) left = left.substring(0, left.length - 1);
    return '$left/$right';
  }
}

class InstallationRecord {
  InstallationRecord({
    required this.bundleId,
    required this.version,
    required this.installedAt,
    required this.copied,
    required this.conflicts,
  });

  final String bundleId;
  final String version;
  final DateTime installedAt;
  final List<String> copied;
  final List<String> conflicts;
}
