/// `SceneBuilderBuiltInApp.knowledgeSources()` shape sanity.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/apps.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SceneBuilderBuiltInApp.knowledgeSources', () {
    const app = SceneBuilderBuiltInApp();

    test('returns a List<Map<String, dynamic>> (no throw)', () async {
      final result = await app.knowledgeSources();
      expect(result, isA<List<Map<String, dynamic>>>());
    });

    test('entries have id + documents list when present', () async {
      final result = await app.knowledgeSources();
      for (final src in result) {
        expect(src['id'], isA<String>());
        expect(src['documents'], isA<List<dynamic>>());
      }
    });
  });
}
