/// project_seed.dart — unit tests.
///
/// `applyOpsProjectSeed` / `applyOpsWorkspaceSeed` use Flutter's
/// `rootBundle.loadString`, requiring `TestWidgetsFlutterBinding`. The
/// assets are registered in `pubspec.yaml` (`lib/src/apps/ops/seed/...`)
/// so they are available in the test bundle.
///
///   s1  isOpsProjectDir — false on empty dir
///   s2  isOpsProjectDir — false when marker absent
///   s3  isOpsProjectDir — true when marker present
///   s4  applyOpsWorkspaceSeed — creates manifest.json at flattened path
///   s5  applyOpsWorkspaceSeed — {{id}} / {{name}} placeholders replaced
///   s6  applyOpsWorkspaceSeed — wsId with slash flattened to underscore
///   s7  applyOpsWorkspaceSeed — idempotent (second call overwrites)
///   s8  applyOpsWorkspaceSeed — _system wsId produces _system.mbd dir
///   s9  applyOpsProjectSeed — creates project.opsproj marker
///   s10 applyOpsProjectSeed — creates project.mbd/manifest.json
///   s11 applyOpsProjectSeed — {{id}} / {{name}} / {{createdAt}} replaced
///   s12 applyOpsProjectSeed — after seeding, isOpsProjectDir returns true
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/apps/ops/infra/project_seed.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isOpsProjectDir', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('seed_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    // --- s1 ---
    test('s1 false on empty directory', () {
      expect(isOpsProjectDir(tmp.path), isFalse);
    });

    // --- s2 ---
    test('s2 false when unrelated file present but no marker', () {
      File(p.join(tmp.path, 'README.md')).writeAsStringSync('hello');
      expect(isOpsProjectDir(tmp.path), isFalse);
    });

    // --- s3 ---
    test('s3 true when project.opsproj marker present', () {
      File(p.join(tmp.path, opsProjectMarker)).writeAsStringSync('{}');
      expect(isOpsProjectDir(tmp.path), isTrue);
    });

    test('s3b false on non-existent path', () {
      expect(isOpsProjectDir('/nonexistent/path/xyz'), isFalse);
    });
  });

  group('applyOpsWorkspaceSeed', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ws_seed_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    // --- s4 ---
    test('s4 creates manifest.json at flattened path', () async {
      await applyOpsWorkspaceSeed(tmp.path, 'project/ws1', 'WS One');
      final f = File(p.join(tmp.path, 'project_ws1.mbd', 'manifest.json'));
      expect(await f.exists(), isTrue);
    });

    // --- s5 ---
    test('s5 placeholders {{id}} and {{name}} are replaced', () async {
      await applyOpsWorkspaceSeed(tmp.path, 'project/ws1', 'WS One');
      final content =
          await File(
            p.join(tmp.path, 'project_ws1.mbd', 'manifest.json'),
          ).readAsString();
      expect(content, contains('project/ws1'));
      expect(content, contains('WS One'));
      expect(content, isNot(contains('{{id}}')));
      expect(content, isNot(contains('{{name}}')));
    });

    // --- s6 ---
    test('s6 wsId with slash is flattened to underscore in dir name', () async {
      await applyOpsWorkspaceSeed(tmp.path, 'org/corp', 'Corp');
      final f = File(p.join(tmp.path, 'org_corp.mbd', 'manifest.json'));
      expect(await f.exists(), isTrue);
    });

    // --- s7 ---
    test('s7 idempotent — second call overwrites without error', () async {
      await applyOpsWorkspaceSeed(tmp.path, 'project/ws2', 'First Name');
      await applyOpsWorkspaceSeed(tmp.path, 'project/ws2', 'Second Name');
      final content =
          await File(
            p.join(tmp.path, 'project_ws2.mbd', 'manifest.json'),
          ).readAsString();
      expect(content, contains('Second Name'));
    });

    // --- s8 ---
    test('s8 _system wsId produces _system.mbd dir', () async {
      await applyOpsWorkspaceSeed(tmp.path, '_system', 'System');
      // _system has no slash, so it becomes _system.mbd (no replacement needed).
      final f = File(p.join(tmp.path, '_system.mbd', 'manifest.json'));
      expect(await f.exists(), isTrue);
    });
  });

  group('applyOpsProjectSeed', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('proj_seed_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    // --- s9 ---
    test('s9 creates project.opsproj marker file', () async {
      await applyOpsProjectSeed(tmp.path, 'MyProject');
      final f = File(p.join(tmp.path, 'project.opsproj'));
      expect(await f.exists(), isTrue);
    });

    // --- s10 ---
    test('s10 creates project.mbd/manifest.json', () async {
      await applyOpsProjectSeed(tmp.path, 'MyProject');
      final f = File(p.join(tmp.path, 'project.mbd', 'manifest.json'));
      expect(await f.exists(), isTrue);
    });

    // --- s11 ---
    test('s11 placeholders in project.opsproj are replaced', () async {
      await applyOpsProjectSeed(tmp.path, 'TestProj');
      final content =
          await File(p.join(tmp.path, 'project.opsproj')).readAsString();
      expect(content, contains('TestProj'));
      expect(content, isNot(contains('{{id}}')));
      expect(content, isNot(contains('{{name}}')));
      expect(content, isNot(contains('{{createdAt}}')));
      // createdAt is replaced by an ISO8601 string.
      expect(content, matches(RegExp(r'\d{4}-\d{2}-\d{2}T')));
    });

    test(
      's11b placeholders in project.mbd/manifest.json are replaced',
      () async {
        await applyOpsProjectSeed(tmp.path, 'TestProj');
        final content =
            await File(
              p.join(tmp.path, 'project.mbd', 'manifest.json'),
            ).readAsString();
        expect(content, contains('TestProj'));
        expect(content, isNot(contains('{{id}}')));
        expect(content, isNot(contains('{{name}}')));
      },
    );

    // --- s12 ---
    test('s12 after seeding, isOpsProjectDir returns true', () async {
      await applyOpsProjectSeed(tmp.path, 'DetectProj');
      expect(isOpsProjectDir(tmp.path), isTrue);
    });

    test('s12b applyOpsProjectSeed is idempotent', () async {
      await applyOpsProjectSeed(tmp.path, 'Proj1');
      await applyOpsProjectSeed(tmp.path, 'Proj2');
      final content =
          await File(p.join(tmp.path, 'project.opsproj')).readAsString();
      expect(content, contains('Proj2'));
    });
  });

  // opsProjectMarker constant
  test('opsProjectMarker constant is project.opsproj', () {
    expect(opsProjectMarker, 'project.opsproj');
  });
}
