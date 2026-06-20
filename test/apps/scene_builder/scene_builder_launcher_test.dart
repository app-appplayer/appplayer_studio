/// `SceneBuilderBuiltInApp.launcher()` — verifies that calling launcher()
/// scaffolds the expected directory and marker file, returns the correct
/// metadata fields, and that subsequent calls (idempotent path) do not throw.
/// The `canHandle`/launcher round-trip is also exercised.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/apps.dart';
import 'package:appplayer_studio/base.dart' show ChromeBridge;

void main() {
  const app = SceneBuilderBuiltInApp();
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scene_launcher_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // l1 — launcher creates the scene_builder subdirectory.
  test('l1: launcher creates scene_builder subdirectory', () {
    final bridge = ChromeBridge();
    app.launcher(bridge, tmp.path);
    final dir = Directory(p.join(tmp.path, 'scene_builder'));
    expect(dir.existsSync(), isTrue);
  });

  // l2 — launcher writes the .builtin_scene_builder marker file.
  test('l2: launcher writes the .builtin_scene_builder marker', () {
    final bridge = ChromeBridge();
    app.launcher(bridge, tmp.path);
    final marker = File(
      p.join(tmp.path, 'scene_builder', '.builtin_scene_builder'),
    );
    expect(marker.existsSync(), isTrue);
  });

  // l3 — returned BuiltInLauncher carries the correct id and label.
  test('l3: launcher returns correct id and label', () {
    final bridge = ChromeBridge();
    final launcher = app.launcher(bridge, tmp.path);
    expect(launcher.id, 'scene_builder');
    expect(launcher.label, 'Scene Builder');
  });

  // l4 — returned launcher iconName is the movie_creation material icon name.
  test('l4: launcher iconName is movie_creation', () {
    final bridge = ChromeBridge();
    final launcher = app.launcher(bridge, tmp.path);
    expect(launcher.iconName, 'movie_creation');
  });

  // l5 — launchPath points to the created scene_builder subdirectory.
  test('l5: launchPath is workspace/scene_builder', () {
    final bridge = ChromeBridge();
    final launcher = app.launcher(bridge, tmp.path);
    expect(launcher.launchPath, p.join(tmp.path, 'scene_builder'));
  });

  // l6 — calling launcher() twice is idempotent (no exception, dir stays).
  test('l6: launcher is idempotent — safe to call twice', () {
    final bridge = ChromeBridge();
    expect(() {
      app.launcher(bridge, tmp.path);
      app.launcher(bridge, tmp.path);
    }, returnsNormally);
    final dir = Directory(p.join(tmp.path, 'scene_builder'));
    expect(dir.existsSync(), isTrue);
  });

  // l7 — canHandle returns true for the path created by launcher (round-trip).
  test('l7: canHandle accepts the path produced by launcher', () {
    final bridge = ChromeBridge();
    final launcher = app.launcher(bridge, tmp.path);
    expect(app.canHandle(launcher.launchPath), isTrue);
  });
}
