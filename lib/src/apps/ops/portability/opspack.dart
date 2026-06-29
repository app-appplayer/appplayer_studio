// Workspace export/import as a portable `.opspack` archive.
// Defined in PRD §FM-PORTABILITY-01 / 02.
//
// Layout of the archive (zip):
//
//   manifest.json      // version, source workspace id, type, created, contents
//   workspace/         // mirror of `<workspacesRoot>/<wsId>/`
//     workspace.yaml
//     members/<id>.yaml
//     skills/...
//     profiles/...
//     philosophies/...
//     facts/...        // when includeFacts=true
//
// Secrets — API keys and AuthProfile cookie jars — are stripped before
// archiving. The importer rejects packs whose manifest version exceeds the
// host's supported version.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

class OpspackManifest {
  OpspackManifest({
    required this.formatVersion,
    required this.sourceWorkspaceId,
    required this.workspaceType,
    required this.createdAt,
    required this.includeFacts,
    required this.contents,
    this.includeSecrets = false,
  });

  /// Bumped only when the layout changes incompatibly.
  static const int currentFormatVersion = 1;

  final int formatVersion;
  final String sourceWorkspaceId;
  final String workspaceType;
  final DateTime createdAt;
  final bool includeFacts;
  final List<String> contents;

  /// True when the pack carries a passphrase-sealed `credentials.sealed`
  /// blob (the workspace's asset credentials). The blob is opaque — opspack
  /// never sees the secrets; sealing/opening is the host `PassphraseSealer`.
  final bool includeSecrets;

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'sourceWorkspaceId': sourceWorkspaceId,
    'workspaceType': workspaceType,
    'createdAt': createdAt.toIso8601String(),
    'includeFacts': includeFacts,
    'includeSecrets': includeSecrets,
    'contents': contents,
  };

  static OpspackManifest fromJson(Map<String, Object?> j) => OpspackManifest(
    formatVersion: (j['formatVersion'] as num).toInt(),
    sourceWorkspaceId: j['sourceWorkspaceId'] as String,
    workspaceType: j['workspaceType'] as String? ?? 'unknown',
    createdAt: DateTime.parse(j['createdAt'] as String),
    includeFacts: j['includeFacts'] as bool? ?? false,
    includeSecrets: j['includeSecrets'] as bool? ?? false,
    contents: (j['contents'] as List?)?.cast<String>() ?? const <String>[],
  );
}

/// Output of [Opspack.exportWorkspace] — the bytes ready to write to disk.
class OpspackBundle {
  OpspackBundle({required this.bytes, required this.manifest});
  final List<int> bytes;
  final OpspackManifest manifest;
}

/// Preview shown to the user before they confirm an import.
class OpspackPreview {
  OpspackPreview({
    required this.manifest,
    required this.fileCount,
    required this.bytes,
  });
  final OpspackManifest manifest;
  final int fileCount;
  final int bytes;
}

class Opspack {
  Opspack._();

  /// Archive entry holding the opaque passphrase-sealed credential blob.
  static const String _credentialsEntry = 'credentials.sealed';

  /// Archive entry holding the project FactGraph snapshot (a map keyed by
  /// collection name), as produced by the knowledge_persistence recipe's
  /// `exportProject`. opspack stays decoupled from the recipe: the caller
  /// serializes the graph and passes the map in; opspack only carries it.
  static const String _factGraphEntry = 'factgraph/graph.json';

  /// Pull the embedded FactGraph snapshot out of a pack, or null if it
  /// carries none. The caller rehydrates it into a project's `.factgraph`
  /// via the recipe's `importProject`.
  static Map<String, List<Map<String, dynamic>>>? extractFactGraph(
    List<int> packBytes,
  ) {
    final archive = ZipDecoder().decodeBytes(packBytes);
    final entry = archive.findFile(_factGraphEntry);
    if (entry == null) return null;
    final decoded =
        json.decode(utf8.decode(entry.content as List<int>)) as Map;
    return <String, List<Map<String, dynamic>>>{
      for (final e in decoded.entries)
        e.key as String: <Map<String, dynamic>>[
          for (final item in (e.value as List))
            (item as Map).cast<String, dynamic>(),
        ],
    };
  }

  /// Pull the sealed credential blob out of a pack, or null if it carries
  /// none. Returned verbatim — the caller unseals it with the passphrase via
  /// the host `PassphraseSealer`.
  static String? extractSealedCredentials(List<int> packBytes) {
    final archive = ZipDecoder().decodeBytes(packBytes);
    final entry = archive.findFile(_credentialsEntry);
    if (entry == null) return null;
    return utf8.decode(entry.content as List<int>);
  }

  /// Build a `.opspack` for the workspace rooted at [workspaceDir].
  ///
  /// Files we never include even if present on disk:
  /// - `secrets.yaml`, `*.key`, `*.pem`, `auth_profile/*` (browser cookie jars)
  /// - any file inside an `auth/` or `secrets/` subtree
  ///
  /// `includeFacts` controls whether facts travel with the pack; off by
  /// default since facts can be regenerated by the host. When on, two things
  /// are carried: any facts files inside the workspace subtree, and — when
  /// [factGraph] is supplied — the project-level disk FactGraph snapshot
  /// (`<projectRoot>/.factgraph`, produced by the recipe's `exportProject`),
  /// embedded as `factgraph/graph.json`. The project graph is shared across a
  /// project's workspaces, so it is passed in by the caller rather than read
  /// from this single workspace's dir.
  ///
  /// `sealedCredentials`, when supplied, is an opaque passphrase-sealed blob
  /// (produced by the host `PassphraseSealer`) carrying the workspace's asset
  /// credentials. It is written verbatim as `credentials.sealed` and flips the
  /// manifest's `includeSecrets`. opspack never sees the plaintext — it only
  /// carries the blob; restoring it on import needs the passphrase.
  static Future<OpspackBundle> exportWorkspace({
    required Directory workspaceDir,
    required String workspaceId,
    String workspaceType = 'unknown',
    bool includeFacts = false,
    String? sealedCredentials,
    Map<String, List<Map<String, dynamic>>>? factGraph,
  }) async {
    if (!await workspaceDir.exists()) {
      throw StateError('Workspace dir not found: ${workspaceDir.path}');
    }

    final archive = Archive();
    final included = <String>[];

    await for (final entity in workspaceDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: workspaceDir.path);
      if (_isSensitive(rel)) continue;
      if (!includeFacts && _isFacts(rel)) continue;
      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile('workspace/$rel', bytes.length, bytes));
      included.add(rel);
    }

    if (includeFacts && factGraph != null && factGraph.isNotEmpty) {
      final graphBytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(factGraph),
      );
      archive.addFile(
        ArchiveFile(_factGraphEntry, graphBytes.length, graphBytes),
      );
      included.add(_factGraphEntry);
    }

    final hasSecrets =
        sealedCredentials != null && sealedCredentials.isNotEmpty;
    if (hasSecrets) {
      final blob = utf8.encode(sealedCredentials);
      archive.addFile(ArchiveFile(_credentialsEntry, blob.length, blob));
    }

    final manifest = OpspackManifest(
      formatVersion: OpspackManifest.currentFormatVersion,
      sourceWorkspaceId: workspaceId,
      workspaceType: workspaceType,
      createdAt: DateTime.now().toUtc(),
      includeFacts: includeFacts,
      includeSecrets: hasSecrets,
      contents: included,
    );
    final manifestBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
    );
    archive.addFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );

    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw StateError('Failed to encode opspack archive');
    }
    return OpspackBundle(bytes: encoded, manifest: manifest);
  }

  /// Read a pack file's manifest + count without unpacking. Used by the
  /// import dialog to show a preview before the user confirms.
  static Future<OpspackPreview> previewFile(File file) async {
    final raw = await file.readAsBytes();
    return previewBytes(raw);
  }

  static OpspackPreview previewBytes(List<int> raw) {
    final archive = ZipDecoder().decodeBytes(raw);
    final manifestEntry = archive.findFile('manifest.json');
    if (manifestEntry == null) {
      throw StateError('Not a valid .opspack — manifest.json missing');
    }
    final manifest = OpspackManifest.fromJson(
      json.decode(utf8.decode(manifestEntry.content as List<int>))
          as Map<String, Object?>,
    );
    if (manifest.formatVersion > OpspackManifest.currentFormatVersion) {
      throw StateError(
        'Pack format ${manifest.formatVersion} newer than host '
        '${OpspackManifest.currentFormatVersion} — upgrade Ops to import.',
      );
    }
    final files = archive.where((f) => f.isFile).length;
    return OpspackPreview(
      manifest: manifest,
      fileCount: files,
      bytes: raw.length,
    );
  }

  /// Conflict policy used when [importWorkspace] meets a workspace whose
  /// id matches the manifest's [sourceWorkspaceId].
  static const conflictRename = 'rename';
  static const conflictSkip = 'skip';
  static const conflictOverwrite = 'overwrite';

  /// Unpack [packFile] into [workspacesRoot]. Returns the workspace id used
  /// (which may be a renamed variant on conflict).
  static Future<String> importWorkspace({
    required File packFile,
    required Directory workspacesRoot,
    String conflictPolicy = conflictRename,
    String? renamedTo,
  }) async {
    final raw = await packFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(raw);
    final manifestEntry = archive.findFile('manifest.json');
    if (manifestEntry == null) {
      throw StateError('Not a valid .opspack — manifest.json missing');
    }
    final manifest = OpspackManifest.fromJson(
      json.decode(utf8.decode(manifestEntry.content as List<int>))
          as Map<String, Object?>,
    );

    String targetId = renamedTo ?? manifest.sourceWorkspaceId;
    final targetDir = Directory(p.join(workspacesRoot.path, targetId));

    if (await targetDir.exists()) {
      switch (conflictPolicy) {
        case conflictSkip:
          return targetId;
        case conflictOverwrite:
          await targetDir.delete(recursive: true);
          break;
        case conflictRename:
        default:
          targetId = _suggestRenamed(
            workspacesRoot,
            manifest.sourceWorkspaceId,
          );
          break;
      }
    }
    final finalDir = Directory(p.join(workspacesRoot.path, targetId));
    await finalDir.create(recursive: true);

    for (final entry in archive) {
      if (!entry.isFile) continue;
      if (entry.name == 'manifest.json') continue;
      if (!entry.name.startsWith('workspace/')) continue;
      final rel = entry.name.substring('workspace/'.length);
      final out = File(p.join(finalDir.path, rel));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(entry.content as List<int>);
    }
    return targetId;
  }

  static bool _isSensitive(String rel) {
    final lower = rel.toLowerCase();
    if (lower.endsWith('.key') || lower.endsWith('.pem')) return true;
    if (lower == 'secrets.yaml' || lower == 'secrets.json') return true;
    final segs = p.split(lower);
    if (segs.contains('secrets') || segs.contains('auth')) return true;
    if (segs.contains('auth_profile')) return true;
    return false;
  }

  static bool _isFacts(String rel) {
    final segs = p.split(rel);
    return segs.contains('facts') || segs.contains('factgraph');
  }

  static String _suggestRenamed(Directory root, String base) {
    var i = 2;
    while (true) {
      final cand = '$base-imported-$i';
      if (!Directory(p.join(root.path, cand)).existsSync()) return cand;
      i += 1;
    }
  }
}
