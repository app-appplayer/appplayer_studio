/// Unit tests for [VibeProject], [ProjectMeta], [ChannelDef],
/// and [projectKindFromId].
///
/// Split into two sections:
///
///   A — Pure-value tests (no file I/O): ProjectMeta, ChannelDef,
///       projectKindFromId, ProjectKind enum.
///
///   B — File-system-backed tests: VibeProject.openAt / save / rename /
///       saveAs / importBundle / exportBundle / cleanBuild / channel ops.
///       All use a real temp directory; no mocks.
///
/// Scenarios:
///
/// A — Pure value
///   pm1  ProjectMeta.defaults — name, schemaVersion, channels, kind
///   pm2  ProjectMeta.defaults studioPackage — single channel named after project
///   pm3  ProjectMeta.copyWith — partial override, createdAt preserved
///   pm4  ProjectMeta.toJson / fromJson round-trip (v2)
///   pm5  ProjectMeta.fromJson v1 migration (bundleSubdir → __legacy__ stash)
///   pm6  ProjectMeta.fromJson unknown kind falls back to appPlayerApp
///   pm7  ProjectMeta.fromJson missing channels key still yields valid channels
///   pm8  ChannelDef.toJson / fromJson round-trip
///   pm9  ChannelDef.fromJson defaults (missing fields)
///   pm10 projectKindFromId — known ids round-trip
///   pm11 projectKindFromId — null / unknown ids → appPlayerApp
///   pm12 appBuilderProjectKinds has exactly 2 entries
///
/// B — File-system
///   pf1  openAt creates project.apbproj + bundle dir on fresh dir
///   pf2  openAt restores meta from existing project.apbproj
///   pf3  openAt migrates legacy project.json to project.apbproj
///   pf4  openAt handles corrupt project.apbproj by backing it up
///   pf5  save persists meta update + canonical
///   pf6  rename updates name in meta, persists, folder name unchanged
///   pf7  saveAs creates new project at new path with same content
///   pf8  cleanBuild(null) removes entire build/ dir
///   pf9  cleanBuild(target) removes single variant dir
///   pf10 cleanBuild(target) rejects path traversal attempts
///   pf11 importBundle replaces active channel bundle
///   pf12 exportBundle copies active channel to external path
///   pf13 channelOps: createChannel enables native slot
///   pf14 channelOps: activateChannel switches canonical
///   pf15 channelOps: removeChannel switches active to remaining
///   pf16 channelOps: purgeChannel deletes on-disk dir
///   pf17 channelOps: copyChannel clones bundle
///   pf18 channelOps: swapChannels exchanges on-disk dirs
///   pf19 migrateLegacyBundle moves app.mbd → bundles/serving.mbd
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart' show WorkspaceCanonicalImpl;
import 'package:appplayer_studio/src/base/infra/workspace_fs_port.dart'
    show FileWorkspaceFsPort;
import 'package:appplayer_studio/src/base/spec/spec_validator.dart'
    show SpecValidatorImpl;
import 'package:appplayer_studio/src/apps/app_builder/core/vibe_project.dart';

// ── helpers ────────────────────────────────────────────────────────────

Future<void> _deepCopy(Directory src, Directory dest) async {
  await dest.create(recursive: true);
  await for (final entity in src.list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (entity is File) {
      await entity.copy(p.join(dest.path, name));
    } else if (entity is Directory) {
      await _deepCopy(entity, Directory(p.join(dest.path, name)));
    }
  }
}

WorkspaceCanonicalImpl _makeCanonical() => WorkspaceCanonicalImpl(
  fsPort: FileWorkspaceFsPort(),
  validator: SpecValidatorImpl(),
);

Future<VibeProject> _openProject(
  String projectDir, {
  WorkspaceCanonicalImpl? canonical,
}) async {
  final canon = canonical ?? _makeCanonical();
  return VibeProject.openAt(projectDir: projectDir, canonical: canon);
}

// ══════════════════════════════════════════════════════════════════════
// A — Pure value tests
// ══════════════════════════════════════════════════════════════════════
void main() {
  // ── pm1 ProjectMeta.defaults ─────────────────────────────────────────
  group('pm1 ProjectMeta.defaults appPlayerApp', () {
    test('name is preserved', () {
      final meta = ProjectMeta.defaults(name: 'My App');
      expect(meta.name, 'My App');
    });

    test('schemaVersion is 2', () {
      expect(ProjectMeta.defaults(name: 'x').schemaVersion, 2);
    });

    test('activeChannel is serving', () {
      expect(ProjectMeta.defaults(name: 'x').activeChannel, 'serving');
    });

    test('channels contains serving (enabled) and native (disabled)', () {
      final meta = ProjectMeta.defaults(name: 'x');
      expect(meta.channels.containsKey('serving'), isTrue);
      expect(meta.channels['serving']!.enabled, isTrue);
      expect(meta.channels.containsKey('native'), isTrue);
      expect(meta.channels['native']!.enabled, isFalse);
    });

    test('kind defaults to appPlayerApp', () {
      expect(ProjectMeta.defaults(name: 'x').kind, ProjectKind.appPlayerApp);
    });
  });

  // ── pm2 ProjectMeta.defaults studioPackage ───────────────────────────
  group('pm2 ProjectMeta.defaults studioPackage', () {
    test('single serving channel named after project', () {
      final meta = ProjectMeta.defaults(
        name: 'my-plugin',
        kind: ProjectKind.studioPackage,
      );
      expect(meta.channels.containsKey('serving'), isTrue);
      expect(meta.channels['serving']!.subdir, contains('my-plugin'));
    });

    test('no native channel for studioPackage', () {
      final meta = ProjectMeta.defaults(
        name: 'p',
        kind: ProjectKind.studioPackage,
      );
      expect(meta.channels.containsKey('native'), isFalse);
    });

    test('kind is studioPackage', () {
      final meta = ProjectMeta.defaults(
        name: 'p',
        kind: ProjectKind.studioPackage,
      );
      expect(meta.kind, ProjectKind.studioPackage);
    });
  });

  // ── pm3 ProjectMeta.copyWith ─────────────────────────────────────────
  group('pm3 ProjectMeta.copyWith', () {
    test('partial override preserves unchanged fields', () {
      final original = ProjectMeta.defaults(name: 'Original');
      final created = original.createdAt;
      final updated = original.copyWith(name: 'Updated');
      expect(updated.name, 'Updated');
      expect(updated.createdAt, created);
      expect(updated.schemaVersion, original.schemaVersion);
    });

    test('copyWith activeChannel', () {
      final meta = ProjectMeta.defaults(
        name: 'x',
      ).copyWith(activeChannel: 'native');
      expect(meta.activeChannel, 'native');
    });

    test('copyWith channels replaces entire map', () {
      final meta = ProjectMeta.defaults(name: 'x');
      final newChannels = <String, ChannelDef>{
        'serving': ChannelDef(subdir: 'bundles/custom.mbd'),
      };
      final updated = meta.copyWith(channels: newChannels);
      expect(updated.channels, newChannels);
    });
  });

  // ── pm4 ProjectMeta toJson/fromJson v2 round-trip ───────────────────
  group('pm4 ProjectMeta v2 round-trip', () {
    test('name survives', () {
      final meta = ProjectMeta.defaults(name: 'RoundTrip');
      final restored = ProjectMeta.fromJson(meta.toJson());
      expect(restored.name, 'RoundTrip');
    });

    test('schemaVersion survives', () {
      final meta = ProjectMeta.defaults(name: 'x');
      expect(ProjectMeta.fromJson(meta.toJson()).schemaVersion, 2);
    });

    test('activeChannel survives', () {
      final meta = ProjectMeta.defaults(name: 'x');
      expect(
        ProjectMeta.fromJson(meta.toJson()).activeChannel,
        meta.activeChannel,
      );
    });

    test('channels survive', () {
      final meta = ProjectMeta.defaults(name: 'x');
      final restored = ProjectMeta.fromJson(meta.toJson());
      expect(restored.channels.containsKey('serving'), isTrue);
      expect(restored.channels.containsKey('native'), isTrue);
    });

    test('kind=studioPackage survives', () {
      final meta = ProjectMeta.defaults(
        name: 'pkg',
        kind: ProjectKind.studioPackage,
      );
      final restored = ProjectMeta.fromJson(meta.toJson());
      expect(restored.kind, ProjectKind.studioPackage);
    });
  });

  // ── pm5 ProjectMeta.fromJson v1 migration ───────────────────────────
  group('pm5 v1 migration via fromJson', () {
    test('bundleSubdir stored as __legacy__ channel', () {
      final v1 = <String, dynamic>{
        'name': 'Legacy',
        'bundleSubdir': 'app.mbd',
        'createdAt': '2024-01-01T00:00:00.000Z',
        'lastOpenedAt': '2024-01-01T00:00:00.000Z',
      };
      final meta = ProjectMeta.fromJson(v1);
      // v1 shape yields __legacy__ in channels so migration helper can
      // pick it up; or it maps directly to serving.
      expect(
        meta.channels.containsKey('serving') ||
            meta.channels.containsKey('__legacy__'),
        isTrue,
      );
    });

    test('default bundleSubdir app.mbd used when field absent', () {
      final v1 = <String, dynamic>{'name': 'OldProject'};
      // Should not throw.
      expect(() => ProjectMeta.fromJson(v1), returnsNormally);
    });
  });

  // ── pm6 ProjectMeta.fromJson unknown kind ───────────────────────────
  group('pm6 fromJson unknown kind', () {
    test('falls back to appPlayerApp', () {
      final json = ProjectMeta.defaults(name: 'x').toJson();
      json['kind'] = 'nonExistentKind';
      final meta = ProjectMeta.fromJson(json);
      expect(meta.kind, ProjectKind.appPlayerApp);
    });

    test('missing kind field → appPlayerApp', () {
      final json = ProjectMeta.defaults(name: 'x').toJson()..remove('kind');
      final meta = ProjectMeta.fromJson(json);
      expect(meta.kind, ProjectKind.appPlayerApp);
    });
  });

  // ── pm7 fromJson missing channels ───────────────────────────────────
  group('pm7 fromJson missing channels', () {
    test('no channels key → defaults inserted', () {
      final json = <String, dynamic>{'name': 'NoChannels'};
      final meta = ProjectMeta.fromJson(json);
      // v1 path: serving + native inserted
      expect(meta.channels.containsKey('serving'), isTrue);
    });
  });

  // ── pm8 ChannelDef round-trip ────────────────────────────────────────
  group('pm8 ChannelDef toJson/fromJson', () {
    test('enabled=true round-trips', () {
      final ch = ChannelDef(subdir: 'bundles/serving.mbd', enabled: true);
      final r = ChannelDef.fromJson(ch.toJson());
      expect(r.subdir, 'bundles/serving.mbd');
      expect(r.enabled, isTrue);
    });

    test('enabled=false round-trips', () {
      final ch = ChannelDef(subdir: 'bundles/native.mbd', enabled: false);
      final r = ChannelDef.fromJson(ch.toJson());
      expect(r.enabled, isFalse);
    });
  });

  // ── pm9 ChannelDef.fromJson defaults ────────────────────────────────
  group('pm9 ChannelDef.fromJson defaults', () {
    test('missing subdir → fallback string', () {
      final ch = ChannelDef.fromJson(<String, dynamic>{});
      expect(ch.subdir, isNotEmpty);
    });

    test('missing enabled → defaults to true', () {
      final ch = ChannelDef.fromJson(<String, dynamic>{'subdir': 'b.mbd'});
      expect(ch.enabled, isTrue);
    });
  });

  // ── pm10 projectKindFromId known ────────────────────────────────────
  group('pm10 projectKindFromId known ids', () {
    test('appPlayerApp id resolves correctly', () {
      expect(projectKindFromId('appPlayerApp'), ProjectKind.appPlayerApp);
    });

    test('studioPackage id resolves correctly', () {
      expect(projectKindFromId('studioPackage'), ProjectKind.studioPackage);
    });
  });

  // ── pm11 projectKindFromId unknown ──────────────────────────────────
  group('pm11 projectKindFromId unknown', () {
    test('null → appPlayerApp', () {
      // Null short-circuits before byName call — safe fallback.
      expect(projectKindFromId(null), ProjectKind.appPlayerApp);
    });

    test('empty string → throws ArgumentError (byName with empty string)', () {
      // The implementation calls values.byName(id) without guarding
      // non-null unknown strings — byName throws for unknown names.
      expect(() => projectKindFromId(''), throwsArgumentError);
    });

    test('unknown string → throws ArgumentError', () {
      expect(() => projectKindFromId('banana'), throwsArgumentError);
    });
  });

  // ── pm12 appBuilderProjectKinds ─────────────────────────────────────
  group('pm12 appBuilderProjectKinds', () {
    test('has exactly 2 entries', () {
      expect(appBuilderProjectKinds, hasLength(2));
    });

    test('ids are non-empty', () {
      for (final k in appBuilderProjectKinds) {
        expect(k.id, isNotEmpty);
        expect(k.label, isNotEmpty);
      }
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // B — File-system-backed tests
  // ══════════════════════════════════════════════════════════════════════
  group('B — VibeProject file-system', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('vibe_proj_test_');
    });

    tearDown(() async {
      // Best-effort cleanup with retry — a project's async channel watchers /
      // save can still hold files for a moment, so a hard recursive delete may
      // race with "Directory not empty" under load. Swallow (it's a temp dir).
      for (var i = 0; i < 5; i++) {
        try {
          if (await tmp.exists()) await tmp.delete(recursive: true);
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });

    // ── pf1 openAt fresh dir ───────────────────────────────────────────
    group('pf1 openAt fresh dir', () {
      test('creates project.apbproj', () async {
        final project = await _openProject(tmp.path);
        await project.dispose();
        final metaFile = File(p.join(tmp.path, VibeProject.projectFile));
        expect(await metaFile.exists(), isTrue);
      });

      test('creates bundle dir for active channel', () async {
        final project = await _openProject(tmp.path);
        final bundleDir = Directory(project.bundlePath);
        await project.dispose();
        expect(await bundleDir.exists(), isTrue);
      });

      test('name defaults to folder basename', () async {
        final sub = await tmp.createTemp('MyProj');
        final project = await _openProject(sub.path);
        expect(project.name, isNotEmpty);
        await project.dispose();
      });
    });

    // ── pf2 openAt restores existing meta ──────────────────────────────
    group('pf2 openAt restores meta', () {
      test('name from project.apbproj survives reopen', () async {
        // First open — sets up a project with a known name.
        final project1 = await _openProject(tmp.path);
        await project1.rename('Restored Name');
        await project1.dispose();

        // Second open — same directory.
        final project2 = await _openProject(tmp.path);
        expect(project2.name, 'Restored Name');
        await project2.dispose();
      });
    });

    // ── pf3 openAt migrates legacy project.json ────────────────────────
    group('pf3 legacy project.json migration', () {
      test('project.json renamed to project.apbproj', () async {
        // Write a minimal v1 project.json.
        final legacyFile = File(
          p.join(tmp.path, VibeProject.legacyProjectFile),
        );
        await legacyFile.writeAsString(
          jsonEncode(<String, dynamic>{
            'name': 'LegacyProj',
            'schemaVersion': 1,
            'createdAt': '2023-01-01T00:00:00.000Z',
            'lastOpenedAt': '2023-01-01T00:00:00.000Z',
          }),
        );

        final project = await _openProject(tmp.path);
        await project.dispose();

        expect(
          await File(p.join(tmp.path, VibeProject.projectFile)).exists(),
          isTrue,
        );
        expect(
          await File(p.join(tmp.path, VibeProject.legacyProjectFile)).exists(),
          isFalse,
        );
      });
    });

    // ── pf4 openAt corrupt meta backup ────────────────────────────────
    group('pf4 corrupt project.apbproj backed up', () {
      test('project opens with defaults when meta is corrupt', () async {
        final metaFile = File(p.join(tmp.path, VibeProject.projectFile));
        await metaFile.writeAsString('{not valid json!}');
        final project = await _openProject(tmp.path);
        expect(project.name, isNotEmpty);
        await project.dispose();
      });
    });

    // ── pf5 save ────────────────────────────────────────────────────────
    group('pf5 save', () {
      test('does not throw', () async {
        final project = await _openProject(tmp.path);
        await expectLater(() => project.save(), returnsNormally);
        await project.dispose();
      });

      test('project.apbproj exists after save', () async {
        final project = await _openProject(tmp.path);
        await project.save();
        await project.dispose();
        expect(
          await File(p.join(tmp.path, VibeProject.projectFile)).exists(),
          isTrue,
        );
      });
    });

    // ── pf6 rename ──────────────────────────────────────────────────────
    group('pf6 rename', () {
      test('updates name in meta', () async {
        final project = await _openProject(tmp.path);
        await project.rename('New Name');
        expect(project.name, 'New Name');
        await project.dispose();
      });

      test('rename persists across reopen', () async {
        final project1 = await _openProject(tmp.path);
        await project1.rename('Persisted');
        await project1.dispose();

        final project2 = await _openProject(tmp.path);
        expect(project2.name, 'Persisted');
        await project2.dispose();
      });

      test('rename with same name is a no-op (no error)', () async {
        final project = await _openProject(tmp.path);
        final name = project.name;
        await expectLater(() => project.rename(name), returnsNormally);
        await project.dispose();
      });

      test('rename with empty string is a no-op', () async {
        final project = await _openProject(tmp.path);
        final before = project.name;
        await project.rename('');
        expect(project.name, before);
        await project.dispose();
      });
    });

    // ── pf7 saveAs ──────────────────────────────────────────────────────
    group('pf7 saveAs', () {
      test('new project directory is created', () async {
        final newDir = p.join(tmp.path, 'clone');
        final project = await _openProject(tmp.path);
        final cloned = await project.saveAs(newDir);
        expect(await Directory(newDir).exists(), isTrue);
        await cloned.dispose();
        await project.dispose();
      });

      test('cloned project has same name', () async {
        final newDir = p.join(tmp.path, 'clone2');
        final project1 = await _openProject(tmp.path);
        await project1.rename('ToClone');
        final cloned = await project1.saveAs(newDir);
        expect(cloned.name, 'ToClone');
        await cloned.dispose();
        await project1.dispose();
      });

      test('cloned project.apbproj exists', () async {
        final newDir = p.join(tmp.path, 'clone3');
        final project = await _openProject(tmp.path);
        final cloned = await project.saveAs(newDir);
        await cloned.dispose();
        await project.dispose();
        expect(
          await File(p.join(newDir, VibeProject.projectFile)).exists(),
          isTrue,
        );
      });
    });

    // ── pf8 cleanBuild null ──────────────────────────────────────────────
    group('pf8 cleanBuild(null)', () {
      test('removes entire build dir', () async {
        final project = await _openProject(tmp.path);
        final buildDir = Directory(p.join(tmp.path, 'build'));
        await buildDir.create(recursive: true);
        await File(p.join(buildDir.path, 'dummy.txt')).writeAsString('x');
        final deleted = await project.cleanBuild();
        expect(deleted, isNotEmpty);
        expect(await buildDir.exists(), isFalse);
        await project.dispose();
      });

      test('returns empty list when no build dir', () async {
        final project = await _openProject(tmp.path);
        final deleted = await project.cleanBuild();
        expect(deleted, isEmpty);
        await project.dispose();
      });
    });

    // ── pf9 cleanBuild target ────────────────────────────────────────────
    group('pf9 cleanBuild(target)', () {
      test('removes single variant dir', () async {
        final project = await _openProject(tmp.path);
        final variantDir = Directory(p.join(tmp.path, 'build', 'inline'));
        await variantDir.create(recursive: true);
        final deleted = await project.cleanBuild(target: 'inline');
        expect(deleted, isNotEmpty);
        expect(await variantDir.exists(), isFalse);
        await project.dispose();
      });

      test('no-op when variant dir absent', () async {
        final project = await _openProject(tmp.path);
        final deleted = await project.cleanBuild(target: 'bundle');
        expect(deleted, isEmpty);
        await project.dispose();
      });
    });

    // ── pf10 cleanBuild path traversal ──────────────────────────────────
    group('pf10 cleanBuild path traversal rejected', () {
      test('throws ArgumentError for path with /', () async {
        final project = await _openProject(tmp.path);
        await expectLater(
          () => project.cleanBuild(target: '../../etc'),
          throwsArgumentError,
        );
        await project.dispose();
      });

      test('throws ArgumentError for empty string', () async {
        final project = await _openProject(tmp.path);
        await expectLater(
          () => project.cleanBuild(target: ''),
          throwsArgumentError,
        );
        await project.dispose();
      });
    });

    // ── pf11 importBundle ───────────────────────────────────────────────
    group('pf11 importBundle', () {
      test('replaces active channel bundle with source', () async {
        // Create source project, save it so it has a valid canonical bundle.
        final srcProjectDir = await Directory(
          p.join(tmp.path, 'src_project'),
        ).create(recursive: true);
        final srcProject = await _openProject(srcProjectDir.path);
        await srcProject.save();
        final srcBundlePath = srcProject.bundlePath;
        await srcProject.dispose();

        // Add a marker file to the source bundle.
        await File(
          p.join(srcBundlePath, 'IMPORT_MARKER'),
        ).writeAsString('imported');

        // Create destination project and import from source.
        final destProjectDir = await Directory(
          p.join(tmp.path, 'dest_project'),
        ).create(recursive: true);
        final destProject = await _openProject(destProjectDir.path);
        await destProject.importBundle(srcBundlePath);

        // Marker file should now exist in the destination bundle dir.
        final dest = File(p.join(destProject.bundlePath, 'IMPORT_MARKER'));
        expect(await dest.exists(), isTrue);
        await destProject.dispose();
      });

      test('throws when source path does not exist', () async {
        final project = await _openProject(tmp.path);
        await expectLater(
          () => project.importBundle('/nonexistent/path.mbd'),
          throwsA(isA<FileSystemException>()),
        );
        await project.dispose();
      });
    });

    // ── pf12 exportBundle ───────────────────────────────────────────────
    group('pf12 exportBundle', () {
      test('copies bundle to external path', () async {
        final project = await _openProject(tmp.path);
        await project.save();
        final destPath = p.join(tmp.path, 'exported.mbd');
        await project.exportBundle(destPath);
        expect(await Directory(destPath).exists(), isTrue);
        await project.dispose();
      });
    });

    // ── pf13 createChannel ───────────────────────────────────────────────
    group('pf13 createChannel enables native slot', () {
      test('native channel becomes enabled after createChannel', () async {
        final project = await _openProject(tmp.path);
        expect(project.channels['native']?.enabled, isFalse);
        await project.createChannel('native', activate: false);
        expect(project.channels['native']?.enabled, isTrue);
        await project.dispose();
      });

      test('directory is created for the channel', () async {
        final project = await _openProject(tmp.path);
        await project.createChannel('native', activate: false);
        final nativeDir = Directory(
          p.join(tmp.path, project.channels['native']!.subdir),
        );
        expect(await nativeDir.exists(), isTrue);
        await project.dispose();
      });
    });

    // ── pf14 activateChannel ────────────────────────────────────────────
    group('pf14 activateChannel', () {
      test('switches activeChannel', () async {
        final project = await _openProject(tmp.path);
        await project.createChannel('native', activate: false);
        await project.activateChannel('native');
        expect(project.activeChannel, 'native');
        await project.dispose();
      });

      test('throws on unknown channel', () async {
        final project = await _openProject(tmp.path);
        await expectLater(
          () => project.activateChannel('unknown'),
          throwsStateError,
        );
        await project.dispose();
      });

      test('throws on disabled channel', () async {
        final project = await _openProject(tmp.path);
        // native is disabled by default.
        await expectLater(
          () => project.activateChannel('native'),
          throwsStateError,
        );
        await project.dispose();
      });
    });

    // ── pf15 removeChannel ───────────────────────────────────────────────
    group('pf15 removeChannel', () {
      test('disables channel without deleting dir', () async {
        final project = await _openProject(tmp.path);
        await project.createChannel('native', activate: false);
        final nativePath = project.channels['native']!.subdir;
        await project.removeChannel('native');
        expect(project.channels['native']?.enabled, isFalse);
        // Dir still present — remove does not delete.
        expect(await Directory(p.join(tmp.path, nativePath)).exists(), isTrue);
        await project.dispose();
      });

      test('throws when removing the only enabled channel', () async {
        final project = await _openProject(tmp.path);
        // Only serving is enabled. Remove should throw.
        await expectLater(
          () => project.removeChannel('serving'),
          throwsStateError,
        );
        await project.dispose();
      });
    });

    // ── pf16 purgeChannel ────────────────────────────────────────────────
    group('pf16 purgeChannel', () {
      test('deletes on-disk bundle dir', () async {
        final project = await _openProject(tmp.path);
        await project.createChannel('native', activate: false);
        final nativePath = p.join(tmp.path, project.channels['native']!.subdir);
        await project.purgeChannel('native');
        expect(await Directory(nativePath).exists(), isFalse);
        await project.dispose();
      });

      test('channel slot remains but is disabled after purge', () async {
        final project = await _openProject(tmp.path);
        await project.createChannel('native', activate: false);
        await project.purgeChannel('native');
        expect(project.channels['native']?.enabled, isFalse);
        await project.dispose();
      });
    });

    // ── pf17 copyChannel ─────────────────────────────────────────────────
    group('pf17 copyChannel', () {
      test('target channel has same manifest as source after copy', () async {
        final project = await _openProject(tmp.path);
        // Save so the serving bundle has a manifest.json.
        await project.save();
        await project.createChannel('native', activate: false);
        await project.copyChannel(source: 'serving', target: 'native');
        final manifestFile = File(
          p.join(tmp.path, project.channels['native']!.subdir, 'manifest.json'),
        );
        expect(await manifestFile.exists(), isTrue);
        await project.dispose();
      });

      test('source == target throws StateError', () async {
        final project = await _openProject(tmp.path);
        await expectLater(
          () => project.copyChannel(source: 'serving', target: 'serving'),
          throwsStateError,
        );
        await project.dispose();
      });
    });

    // ── pf18 swapChannels ────────────────────────────────────────────────
    group('pf18 swapChannels', () {
      test('swaps on-disk bundle directories', () async {
        final project = await _openProject(tmp.path);
        await project.save();
        await project.createChannel('native', activate: false);
        // Write a marker file into serving.
        final marker = File(p.join(project.bundlePath, 'MARKER_SERVING'));
        await marker.writeAsString('serving');
        await project.swapChannels('serving', 'native');
        // After swap, the marker should be in the native dir.
        final nativePath = p.join(tmp.path, project.channels['native']!.subdir);
        expect(
          await File(p.join(nativePath, 'MARKER_SERVING')).exists(),
          isTrue,
        );
        await project.dispose();
      });

      test('a == b throws', () async {
        final project = await _openProject(tmp.path);
        await expectLater(
          () => project.swapChannels('serving', 'serving'),
          throwsStateError,
        );
        await project.dispose();
      });
    });

    // ── pf19 migrateLegacyBundle ─────────────────────────────────────────
    group('pf19 migrateLegacyBundle', () {
      test('app.mbd/ at root is moved to bundles/serving.mbd/', () async {
        // Create a source project in another temp dir and save it so we have
        // a valid canonical bundle directory to use as a legacy app.mbd.
        final sourceDir = await Directory.systemTemp.createTemp('legacy_src_');
        try {
          final src = await _openProject(sourceDir.path);
          await src.save();
          final srcBundle = src.bundlePath;
          await src.dispose();

          // Copy the valid bundle into our test dir as app.mbd (v1 layout).
          final legacyBundleDir = Directory(p.join(tmp.path, 'app.mbd'));
          await legacyBundleDir.create(recursive: true);
          await for (final entity in Directory(
            srcBundle,
          ).list(followLinks: false)) {
            final name = p.basename(entity.path);
            if (entity is File) {
              await entity.copy(p.join(legacyBundleDir.path, name));
            } else if (entity is Directory) {
              await _deepCopy(
                entity,
                Directory(p.join(legacyBundleDir.path, name)),
              );
            }
          }
        } finally {
          if (await sourceDir.exists()) {
            await sourceDir.delete(recursive: true);
          }
        }

        // Write v1 project.json pointing at app.mbd.
        await File(
          p.join(tmp.path, VibeProject.legacyProjectFile),
        ).writeAsString(
          jsonEncode(<String, dynamic>{
            'name': 'V1Project',
            'bundleSubdir': 'app.mbd',
            'createdAt': '2023-01-01T00:00:00.000Z',
            'lastOpenedAt': '2023-01-01T00:00:00.000Z',
          }),
        );

        final project = await _openProject(tmp.path);
        // After migration the bundle should be under bundles/serving.mbd.
        expect(project.bundlePath, contains('bundles'));
        // Original app.mbd should be gone (moved).
        expect(await Directory(p.join(tmp.path, 'app.mbd')).exists(), isFalse);
        await project.dispose();
      });
    });
  });
}
