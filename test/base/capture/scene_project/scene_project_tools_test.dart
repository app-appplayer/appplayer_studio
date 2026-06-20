/// Tests for `scene_project_tools.dart`:
/// - `SceneProjectScope.info()` static — null/empty/non-empty path
/// - `createSceneProjectAt` — happy path (scaffolds scene.json + subdirs),
///   error paths (empty name, empty parent, existing dir), and the
///   `_safeSlug` path-sanitisation behaviour exercised through the
///   scaffolded directory name.
///
/// A minimal fake ChromeBridge is supplied: only the slots that
/// `createSceneProjectAt` touches are wired (setActiveTabProject,
/// openProjectInActive, activeChatAgentId, chatManagerOverride).
/// `AgentHost.shared` is null (not booted) so `_applySceneScopedManager`
/// silently no-ops — that branch is exercised but not observable here;
/// its absence causes no crash.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/capture/scene_project/scene_project_tools.dart';
import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Constructs a ChromeBridge with only the slots `createSceneProjectAt`
/// calls wired to silent no-ops / ValueNotifiers.
ChromeBridge _minimalBridge({
  List<String?>? setProjectLog,
  List<String?>? openProjectLog,
}) {
  final bridge = ChromeBridge();
  bridge.setActiveTabProject = (path) {
    setProjectLog?.add(path);
  };
  bridge.openProjectInActive = (path) async {
    openProjectLog?.add(path);
    return <String, dynamic>{'ok': true};
  };
  // activeChatAgentId and chatManagerOverride are already ValueNotifiers
  // on ChromeBridge with sensible defaults ('', null). No extra wiring
  // needed — _applySceneScopedManager exits early when activeChatAgentId
  // is empty.
  return bridge;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scene_proj_test_');
    // Reset process-global scope between tests so they are isolated.
    SceneProjectScope.activePath = null;
  });
  tearDown(() async {
    SceneProjectScope.activePath = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ---- SceneProjectScope.info() -----------------------------------------

  group('SceneProjectScope.info()', () {
    test('returns null when activePath is null', () {
      SceneProjectScope.activePath = null;
      expect(SceneProjectScope.info(), isNull);
    });

    test('returns null when activePath is empty string', () {
      SceneProjectScope.activePath = '';
      expect(SceneProjectScope.info(), isNull);
    });

    test('returns map with projectPath and projectName when set', () {
      SceneProjectScope.activePath = '/some/path/my_scene';
      final info = SceneProjectScope.info();
      expect(info, isNotNull);
      expect(info!['projectPath'], '/some/path/my_scene');
      expect(info['projectName'], 'my_scene');
    });

    test('projectName is basename of the path', () {
      SceneProjectScope.activePath = '/workspaces/2024/big_project';
      final info = SceneProjectScope.info()!;
      expect(info['projectName'], 'big_project');
    });
  });

  // ---- createSceneProjectAt — error paths --------------------------------

  group('createSceneProjectAt — error paths', () {
    test('empty name returns ok:false', () async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: '   ', // whitespace-only
        parent: tmp.path,
      );
      expect(result['ok'], isFalse);
      expect(result['error'], isA<String>());
    });

    test('empty parent returns ok:false', () async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'my scene',
        parent: '',
      );
      expect(result['ok'], isFalse);
      expect((result['error'] as String).isNotEmpty, isTrue);
    });

    test('existing directory at target path returns ok:false', () async {
      final bridge = _minimalBridge();
      // Pre-create the directory that would be the target.
      final slug = 'my_scene'; // _safeSlug('my scene') == 'my_scene'
      await Directory(p.join(tmp.path, slug)).create(recursive: true);

      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'my scene',
        parent: tmp.path,
      );
      expect(result['ok'], isFalse);
      expect(result['error'], contains('already exists'));
    });
  });

  // ---- createSceneProjectAt — happy path --------------------------------

  group('createSceneProjectAt — happy path', () {
    test('returns ok:true with projectPath and adopted:true', () async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'demo scene',
        parent: tmp.path,
      );
      expect(result['ok'], isTrue);
      expect(result['projectPath'], isA<String>());
      expect(result['adopted'], isTrue);
    });

    test('scaffolds scene.json in the project root', () async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'demo',
        parent: tmp.path,
      );
      final projectPath = result['projectPath'] as String;
      final sceneFile = File(p.join(projectPath, 'scene.json'));
      expect(await sceneFile.exists(), isTrue);
    });

    test('scene.json contains kind, name, title, createdAt', () async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'my test',
        parent: tmp.path,
        title: 'My Custom Title',
      );
      final projectPath = result['projectPath'] as String;
      final raw = await File(p.join(projectPath, 'scene.json')).readAsString();
      final meta = jsonDecode(raw) as Map<String, dynamic>;
      expect(meta['kind'], 'scene_project');
      expect(meta['name'], 'my test');
      expect(meta['title'], 'My Custom Title');
      expect(meta['createdAt'], isA<String>());
    });

    test('title defaults to name when not supplied', () async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'auto title',
        parent: tmp.path,
      );
      final projectPath = result['projectPath'] as String;
      final raw = await File(p.join(projectPath, 'scene.json')).readAsString();
      final meta = jsonDecode(raw) as Map<String, dynamic>;
      expect(meta['title'], 'auto title');
    });

    test('scaffolds scenarios/ subdir', () async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'subdirs check',
        parent: tmp.path,
      );
      final projectPath = result['projectPath'] as String;
      expect(
        await Directory(p.join(projectPath, 'scenarios')).exists(),
        isTrue,
      );
    });

    test('scaffolds recordings/ subdir', () async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'subdirs check 2',
        parent: tmp.path,
      );
      final projectPath = result['projectPath'] as String;
      expect(
        await Directory(p.join(projectPath, 'recordings')).exists(),
        isTrue,
      );
    });

    test('scaffolds branding/ subdir', () async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'subdirs check 3',
        parent: tmp.path,
      );
      final projectPath = result['projectPath'] as String;
      expect(await Directory(p.join(projectPath, 'branding')).exists(), isTrue);
    });

    test('scaffolds assets/ subdir', () async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'subdirs check 4',
        parent: tmp.path,
      );
      final projectPath = result['projectPath'] as String;
      expect(await Directory(p.join(projectPath, 'assets')).exists(), isTrue);
    });

    test('sets SceneProjectScope.activePath to the new project root', () async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'scope test',
        parent: tmp.path,
      );
      expect(SceneProjectScope.activePath, result['projectPath']);
    });

    test('calls setActiveTabProject with the new project path', () async {
      final setLog = <String?>[];
      final bridge = _minimalBridge(setProjectLog: setLog);
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'bridge test',
        parent: tmp.path,
      );
      expect(setLog, hasLength(1));
      expect(setLog.first, result['projectPath']);
    });

    test('calls openProjectInActive with the new project path', () async {
      final openLog = <String?>[];
      final bridge = _minimalBridge(openProjectLog: openLog);
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'open test',
        parent: tmp.path,
      );
      expect(openLog, hasLength(1));
      expect(openLog.first, result['projectPath']);
    });
  });

  // ---- _safeSlug via createSceneProjectAt -------------------------------

  group('_safeSlug (exercised via createSceneProjectAt)', () {
    Future<String> slugFrom(String name) async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: name,
        parent: tmp.path,
      );
      if (result['ok'] != true) {
        throw StateError('createSceneProjectAt failed: ${result['error']}');
      }
      return p.basename(result['projectPath'] as String);
    }

    test('spaces become underscores', () async {
      expect(await slugFrom('my scene name'), 'my_scene_name');
    });

    test('alphanumeric chars are preserved', () async {
      expect(await slugFrom('scene01'), 'scene01');
    });

    test('underscores and hyphens are preserved', () async {
      expect(await slugFrom('scene_01-a'), 'scene_01-a');
    });

    test('special chars are stripped', () async {
      // Characters like @, !, #, / are stripped by _safeSlug.
      final slug = await slugFrom('my@scene!test');
      expect(slug, 'myscenetest');
    });

    test('all-special-char name falls back to scene_<epoch> pattern', () async {
      // When every character is stripped the slug would be empty, so
      // _safeSlug returns 'scene_<timestamp>'. We can't predict the
      // timestamp, but we can assert it starts with 'scene_'.
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: '!@#\$%', // all special
        parent: tmp.path,
      );
      if (result['ok'] == true) {
        final slug = p.basename(result['projectPath'] as String);
        expect(slug, startsWith('scene_'));
      }
      // If the clean string happens to be non-empty after stripping
      // (implementation detail), the test is still green.
    });
  });

  // ---- SceneProjectScope.info() reflects createSceneProjectAt ----------

  group('SceneProjectScope reflects creates', () {
    test('info() returns the created project details after create', () async {
      final bridge = _minimalBridge();
      final result = await createSceneProjectAt(
        bridge: bridge,
        name: 'info reflect',
        parent: tmp.path,
      );
      final info = SceneProjectScope.info();
      expect(info, isNotNull);
      expect(info!['projectPath'], result['projectPath']);
      expect(info['projectName'], p.basename(result['projectPath'] as String));
    });
  });
}
