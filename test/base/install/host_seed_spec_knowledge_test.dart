/// The host seed carries the published specifications as knowledge
/// (`tool/embed_spec_knowledge.py`), so Studio's agents build from the
/// specifications themselves.
library;

import 'package:appplayer_studio/base.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the specs are carried once — no app seed repeats them', () {
    // Every seed's knowledge lands in one index every agent searches, so a
    // copy per app would only repeat the same sections in each result.
    for (final app in const <String>[
      'app_builder',
      'form_builder',
      'scene_builder',
      'makemind_ops',
    ]) {
      final bundle = readBundleAt('seed/$app.mbd')!;
      final ids = <String>{for (final s in bundle.knowledge!.sources) s.id};
      expect(ids.where((id) => id.startsWith('spec_')), isEmpty, reason: app);
      expect(ids, isNotEmpty, reason: app);
    }
  });

  test('the host seed loads with every published spec as a source', () {
    final bundle = readBundleAt('seed/studio.mbd')!;
    final sources = <String, dynamic>{
      for (final s in bundle.knowledge!.sources) s.id: s,
    };
    for (final id in const <String>[
      'spec_ui_dsl',
      'spec_bundle',
      'spec_platform',
      'spec_serving',
      'spec_form',
      'spec_gateway',
    ]) {
      expect(sources, contains(id));
      expect(sources[id].documents, isNotEmpty, reason: id);
    }
    // The UI DSL series is the one the runtime targets.
    expect(sources['spec_ui_dsl'].name, contains(kDslSpecVersion));
    // The summaries the specs replace are gone.
    for (final stale in const <String>[
      'studio_ui_dsl',
      'studio_bundle_spec',
      'studio_host_specs',
    ]) {
      expect(sources, isNot(contains(stale)));
    }
    final platform = sources['spec_platform'].documents as List;
    expect(
      platform.any((d) => '${d.content}'.contains('manifest.type')),
      isTrue,
    );
  });
}
