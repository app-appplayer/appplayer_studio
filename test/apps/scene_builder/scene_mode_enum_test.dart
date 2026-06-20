/// `SceneMode` enum — pure value contract: five distinct modes in the
/// canonical order [scenarios, edit, recordings, video, branding]. The
/// _ModeStrip `_order` list drives the tab strip index mapping and must
/// cover every enum value with no extras — pinned here so regressions
/// (accidental value addition / removal) fail immediately before touching
/// the tab UI. (`video` = the trim/join editor for existing clips.)
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/scene_builder/feat/scene_shell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SceneMode enum', () {
    // m1 — exactly five values.
    test('m1: has exactly five values', () {
      expect(SceneMode.values, hasLength(5));
    });

    // m2 — canonical order matches the mode strip.
    test(
      'm2: canonical order is scenarios, edit, recordings, video, branding',
      () {
        expect(SceneMode.values, <SceneMode>[
          SceneMode.scenarios,
          SceneMode.edit,
          SceneMode.recordings,
          SceneMode.video,
          SceneMode.branding,
        ]);
      },
    );

    // m3 — all values have distinct names (no accidental duplicate).
    test('m3: all values have distinct names', () {
      final names = SceneMode.values.map((v) => v.name).toList();
      expect(names.toSet(), hasLength(names.length));
    });

    // m4 — specific names match expected strings.
    test('m4: value names match', () {
      expect(SceneMode.scenarios.name, 'scenarios');
      expect(SceneMode.edit.name, 'edit');
      expect(SceneMode.recordings.name, 'recordings');
      expect(SceneMode.video.name, 'video');
      expect(SceneMode.branding.name, 'branding');
    });

    // m5 — index values are 0-based in canonical order.
    test('m5: index values are 0–4 in order', () {
      expect(SceneMode.scenarios.index, 0);
      expect(SceneMode.edit.index, 1);
      expect(SceneMode.recordings.index, 2);
      expect(SceneMode.video.index, 3);
      expect(SceneMode.branding.index, 4);
    });
  });
}
