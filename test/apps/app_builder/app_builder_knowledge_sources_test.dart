/// `AppBuilderBuiltInApp.knowledgeSources()` returns a List on success
/// or falls back to an empty list on read failure — verifying the
/// host's boot loop never throws while fanning out the bundled
/// knowledge JSON as MCP resources.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/apps.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppBuilderBuiltInApp.knowledgeSources', () {
    const app = AppBuilderBuiltInApp();

    test('returns a List<Map<String, dynamic>> (no throw)', () async {
      final result = await app.knowledgeSources();
      expect(result, isA<List<Map<String, dynamic>>>());
    });

    test('every entry exposes an id and a documents list', () async {
      // Whether or not the asset is bundled, every returned source must
      // carry an `id` string + a `documents` list — the boot fan-out
      // assumes that shape when emitting MCP resources.
      final result = await app.knowledgeSources();
      for (final src in result) {
        expect(src['id'], isA<String>());
        expect(src['documents'], isA<List<dynamic>>());
      }
    });
  });
}
