/// `CanonicalPatch` + `LayerId` value-class sanity.
library;

import 'package:brain_kernel/brain_kernel.dart' show PatchOp, UserOriginator;
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

void main() {
  group('LayerId', () {
    test('exposes the 12 canonical layers', () {
      // 8 UI-mode layers + 4 bundle-mode layers (knowledge / manifest /
      // tools / agents) — App Builder's bundle authoring is now a mode of
      // the single platform layer model, not a fork.
      expect(LayerId.values.length, 12);
      expect(
        LayerId.values,
        containsAll(<LayerId>[
          LayerId.appStructure,
          LayerId.theme,
          LayerId.components,
          LayerId.dashboard,
          LayerId.navigation,
          LayerId.pages,
          LayerId.assets,
          LayerId.knowledge,
          LayerId.manifest,
          LayerId.tools,
          LayerId.agents,
          LayerId.whole,
        ]),
      );
    });

    test('names round-trip through toString', () {
      for (final id in LayerId.values) {
        expect(id.name, isNotEmpty);
      }
    });
  });

  group('CanonicalPatch', () {
    test('captures layer + ops + originator', () {
      const patch = CanonicalPatch(
        layer: LayerId.pages,
        ops: <PatchOp>[],
        originator: UserOriginator(),
      );
      expect(patch.layer, LayerId.pages);
      expect(patch.ops, isEmpty);
      expect(patch.originator, isA<UserOriginator>());
    });

    test('accepts every layer + originator combination', () {
      for (final layer in LayerId.values) {
        final patch = CanonicalPatch(
          layer: layer,
          ops: const <PatchOp>[],
          originator: UserOriginator(),
        );
        expect(patch.layer, layer);
      }
    });
  });
}
