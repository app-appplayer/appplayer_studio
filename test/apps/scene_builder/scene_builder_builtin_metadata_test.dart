/// `SceneBuilderBuiltInApp` metadata sanity — Scene Builder built-in
/// (the scenario authoring / recording / replay surface).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/apps.dart';

void main() {
  group('SceneBuilderBuiltInApp metadata', () {
    const app = SceneBuilderBuiltInApp();

    test('id is "scene_builder"', () {
      expect(app.id, 'scene_builder');
    });

    test('label is "Scene Builder"', () {
      expect(app.label, 'Scene Builder');
    });

    test('id / label non-empty', () {
      expect(app.id, isNotEmpty);
      expect(app.label, isNotEmpty);
    });
  });
}
