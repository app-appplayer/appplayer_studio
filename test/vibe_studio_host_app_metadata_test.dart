/// `VibeStudioHostApp` metadata — host-level identity (toolId,
/// displayName, defaultPort). Catches accidental port/path collisions
/// between debug and release trees (see memory
/// `project-vibe-studio-paths`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/main/vibe_studio_host_app.dart';

void main() {
  group('VibeStudioHostApp metadata (debug tree)', () {
    final app = VibeStudioHostApp();

    test('toolId is "vibe_studio_debug" (debug isolation)', () {
      // The debug tree must NOT share a configRoot with the release
      // tree. If this ever flips back to "vibe_studio" the two trees
      // collide on ~/.config/<toolId>/ and the user loses settings.
      expect(app.toolId, 'vibe_studio_debug');
    });

    test('displayName is "AppPlayer Studio" (no build-mode suffix)', () {
      // The "(debug)" suffix was removed — the base studio shows a clean
      // product name. The pro tier overrides this to "AppPlayer Studio Pro".
      expect(app.displayName, 'AppPlayer Studio');
    });

    test('defaultPort is 7840 (debug)', () {
      // Release uses 7830 — the two trees must coexist on the same
      // machine. Changing this default without changing both trees
      // re-introduces port collisions.
      expect(app.defaultPort, 7840);
    });

    test('toolId / displayName non-empty', () {
      expect(app.toolId, isNotEmpty);
      expect(app.displayName, isNotEmpty);
    });
  });
}
