/// Building blocks of Ops's last-project restore (`OpsShell._restoreLastProject`):
/// the sidecar `lastProjectPath` round-trips through `VibeSettings`, and
/// `isOpsProjectDir` recognises a seeded project but not a bare directory.
/// Together these are what a freshly mounted `OpsShell` reads to reopen the
/// previously bound project after a tab close + reopen (App Builder parity).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/settings/vibe_settings.dart';
import 'package:appplayer_studio/src/apps/ops/infra/project_seed.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ops_restore_test_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('lastProjectPath persistence', () {
    test('save → load round-trips lastProjectPath', () async {
      final cfg = p.join(tmp.path, 'settings.json');
      final projectDir = p.join(tmp.path, 'my_ops_project');

      final s = await VibeSettings.load(cfg); // absent file → defaults
      expect(s.lastProjectPath, isNull);
      s.lastProjectPath = projectDir;
      await s.save(cfg);

      final reloaded = await VibeSettings.load(cfg);
      expect(reloaded.lastProjectPath, projectDir);
    });
  });

  group('isOpsProjectDir', () {
    test('true for a directory holding the project.opsproj marker', () async {
      final dir = p.join(tmp.path, 'project');
      await Directory(dir).create(recursive: true);
      await File(p.join(dir, 'project.opsproj')).writeAsString('{}');
      expect(isOpsProjectDir(dir), isTrue);
    });

    test('false for a bare directory (no marker)', () async {
      final dir = p.join(tmp.path, 'not_a_project');
      await Directory(dir).create(recursive: true);
      expect(isOpsProjectDir(dir), isFalse);
    });
  });

  test('restore decision: a remembered, still-valid project is reopenable',
      () async {
    // Mirrors `_restoreLastProject`: bundlePath is not a project, so the
    // remembered `lastProjectPath` is consulted and — being a valid Ops
    // project — is the one to reopen.
    final cfg = p.join(tmp.path, 'settings.json');
    final project = p.join(tmp.path, 'remembered');
    await Directory(project).create(recursive: true);
    await File(p.join(project, 'project.opsproj')).writeAsString('{}');

    final s = await VibeSettings.load(cfg);
    s.lastProjectPath = project;
    await s.save(cfg);

    final reloaded = await VibeSettings.load(cfg);
    final last = reloaded.lastProjectPath;
    final shouldReopen =
        last != null && last.isNotEmpty && isOpsProjectDir(last);
    expect(shouldReopen, isTrue);
    expect(last, project);
  });
}
