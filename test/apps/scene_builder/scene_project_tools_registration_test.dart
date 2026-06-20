/// `registerSceneProjectTools` — verifies that the three
/// `studio.scene.project.*` tools are registered on an
/// `InProcessKernelServerHost` and that their handlers produce the
/// correct responses for edge-case inputs.
///
/// Uses the same `mk.InProcessKernelServerHost` pattern as
/// `test/base/install/builtin_tools_gate_test.dart`. No live ChromeBridge
/// wiring needed — the tools read `SceneProjectScope.activePath` (process
/// global) and the bridge slots only; we supply a minimal bridge.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_studio/src/base/capture/scene_project/scene_project_tools.dart';
import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';

// Builds a minimal ChromeBridge with the mandatory slots set to no-ops.
ChromeBridge _bridge() {
  final b = ChromeBridge();
  b.setActiveTabProject = (_) {};
  b.openProjectInActive =
      (path) async => <String, dynamic>{'ok': true, 'projectPath': path};
  return b;
}

// Reads the JSON text from the first text content item.
Map<String, dynamic> _json(mk.KernelToolResult result) {
  final text = result.content.whereType<mk.KernelTextContent>().first.text;
  return jsonDecode(text) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late mk.InProcessKernelServerHost boot;
  late ChromeBridge bridge;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scene_proj_tools_test_');
    boot = mk.InProcessKernelServerHost();
    bridge = _bridge();
    SceneProjectScope.activePath = null;
    registerSceneProjectTools(boot, bridge: bridge, configRoot: tmp.path);
  });

  tearDown(() async {
    SceneProjectScope.activePath = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // t1 — studio.scene.project.new is registered.
  test('t1: studio.scene.project.new is registered', () {
    expect(
      boot.toolDefinitions.any((t) => t.name == 'studio.scene.project.new'),
      isTrue,
    );
  });

  // t2 — studio.scene.project.open is registered.
  test('t2: studio.scene.project.open is registered', () {
    expect(
      boot.toolDefinitions.any((t) => t.name == 'studio.scene.project.open'),
      isTrue,
    );
  });

  // t3 — studio.scene.project.info is registered.
  test('t3: studio.scene.project.info is registered', () {
    expect(
      boot.toolDefinitions.any((t) => t.name == 'studio.scene.project.info'),
      isTrue,
    );
  });

  // t4 — studio.scene.project.new returns ok:false on empty name.
  test('t4: project.new with empty name returns ok:false', () async {
    final result = await boot.callTool(
      'studio.scene.project.new',
      <String, dynamic>{'name': '   ', 'parent': tmp.path},
    );
    final json = _json(result);
    expect(json['ok'], isFalse);
    expect(json['error'], isA<String>());
  });

  // t5 — studio.scene.project.info returns {active:false} when no project open.
  test(
    't5: project.info returns active:false when no project is open',
    () async {
      final result = await boot.callTool(
        'studio.scene.project.info',
        const <String, dynamic>{},
      );
      final json = _json(result);
      expect(json['active'], isFalse);
    },
  );

  // t6 — studio.scene.project.new happy path creates scene.json + subdirs.
  test('t6: project.new happy path scaffolds scene.json + subdirs', () async {
    final result = await boot.callTool(
      'studio.scene.project.new',
      <String, dynamic>{'name': 'my test scene', 'parent': tmp.path},
    );
    final json = _json(result);
    expect(json['ok'], isTrue);
    final projectPath = json['projectPath'] as String;
    expect(File(p.join(projectPath, 'scene.json')).existsSync(), isTrue);
    expect(Directory(p.join(projectPath, 'scenarios')).existsSync(), isTrue);
    expect(Directory(p.join(projectPath, 'recordings')).existsSync(), isTrue);
    expect(Directory(p.join(projectPath, 'branding')).existsSync(), isTrue);
    expect(Directory(p.join(projectPath, 'assets')).existsSync(), isTrue);
  });

  // t7 — studio.scene.project.info returns the project after new.
  test('t7: project.info returns active:true after successful new', () async {
    await boot.callTool('studio.scene.project.new', <String, dynamic>{
      'name': 'info_test',
      'parent': tmp.path,
    });
    final result = await boot.callTool(
      'studio.scene.project.info',
      const <String, dynamic>{},
    );
    final json = _json(result);
    expect(json['active'], isTrue);
    expect(json['projectPath'], isA<String>());
  });

  // t8 — studio.scene.project.open returns error for missing scene.json.
  test('t8: project.open returns error when path has no scene.json', () async {
    final emptyDir = Directory(p.join(tmp.path, 'empty_dir'));
    await emptyDir.create();
    final result = await boot.callTool(
      'studio.scene.project.open',
      <String, dynamic>{'path': emptyDir.path},
    );
    final json = _json(result);
    expect(json['ok'], isFalse);
    expect(json['error'], isA<String>());
  });

  // t9 — studio.scene.project.open succeeds when scene.json exists.
  test('t9: project.open accepts a valid scene project directory', () async {
    // Scaffold a minimal scene project manually.
    final sceneDir = Directory(p.join(tmp.path, 'valid_scene'));
    await sceneDir.create();
    await File(
      p.join(sceneDir.path, 'scene.json'),
    ).writeAsString('{"kind":"scene_project","name":"valid"}');

    final result = await boot.callTool(
      'studio.scene.project.open',
      <String, dynamic>{'path': sceneDir.path},
    );
    final json = _json(result);
    expect(json['ok'], isTrue);
    expect(json['projectPath'], sceneDir.path);
  });

  // t10 — studio.scene.project.new with duplicate path returns ok:false.
  test('t10: project.new on existing path returns ok:false', () async {
    // Create first time.
    await boot.callTool('studio.scene.project.new', <String, dynamic>{
      'name': 'dup_scene',
      'parent': tmp.path,
    });
    // Second create with same name/parent should fail.
    final result = await boot.callTool(
      'studio.scene.project.new',
      <String, dynamic>{'name': 'dup_scene', 'parent': tmp.path},
    );
    final json = _json(result);
    expect(json['ok'], isFalse);
    expect(json['error'], contains('already exists'));
  });
}
