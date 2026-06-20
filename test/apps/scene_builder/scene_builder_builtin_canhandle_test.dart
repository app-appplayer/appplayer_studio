/// `SceneBuilderBuiltInApp.canHandle` — accepts a path when the
/// `.builtin_scene_builder` marker file is present.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/apps.dart';

void main() {
  group('SceneBuilderBuiltInApp.canHandle', () {
    const app = SceneBuilderBuiltInApp();
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('scene_builder_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('false when path does not exist', () {
      expect(app.canHandle('/nonexistent/path/foo'), isFalse);
    });

    test('false on empty directory (no marker)', () {
      expect(app.canHandle(tmp.path), isFalse);
    });

    test('true when `.builtin_scene_builder` marker exists', () {
      File(p.join(tmp.path, '.builtin_scene_builder')).writeAsStringSync('');
      expect(app.canHandle(tmp.path), isTrue);
    });

    test(
      'false when a stale `.builtin_app_builder` marker is the only file',
      () {
        // Marker is built-in specific — scene_builder must NOT accept
        // app_builder's marker.
        File(p.join(tmp.path, '.builtin_app_builder')).writeAsStringSync('');
        expect(app.canHandle(tmp.path), isFalse);
      },
    );
  });
}
