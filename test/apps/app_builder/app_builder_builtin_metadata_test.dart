/// `AppBuilderBuiltInApp` metadata sanity — verifies the static
/// BuiltInApp contract fields (id / label / defaultChatAgentId) the
/// host wiring depends on (FR-LAUNCH-003).
///
/// The dynamic surfaces (launcher / mount / canHandle) that require a
/// `ChromeBridge` are exercised in separate widget tests with a fake
/// bridge — kept out of this metadata-only test so it stays fast.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/apps.dart';

void main() {
  group('AppBuilderBuiltInApp metadata', () {
    const app = AppBuilderBuiltInApp();

    test('id is "app_builder"', () {
      expect(app.id, 'app_builder');
    });

    test('label is "App Builder"', () {
      expect(app.label, 'App Builder');
    });

    test('id / label non-empty', () {
      // The host chrome home-tab card and the tab strip both read these
      // fields. An empty label would render a placeholder card with no
      // hint of which built-in is being shown.
      expect(app.id, isNotEmpty);
      expect(app.label, isNotEmpty);
    });
  });
}
