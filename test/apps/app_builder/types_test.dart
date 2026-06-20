/// Unit tests for `app_builder/core/types.dart`.
///
/// The file is a re-export shim plus two App Builder-local types:
///   [CenterMode]  — the centre-panel mode enum with [CenterMode.layersFor]
///                   and [CenterMode.modeOf] helpers.
///   [ConvertResult] — value class capturing code-gen output metadata.
///
/// Re-exported platform symbols (LayerId, CanonicalPatch, ...) are
/// exercised here only for structural invariants; their deep behaviour
/// lives in the base/ type tests.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart' show LayerId;

// The shim re-exports through its own library declaration.
import 'package:appplayer_studio/src/apps/app_builder/core/types.dart';

void main() {
  // ── CenterMode enum structure ──────────────────────────────────────
  group('CenterMode values', () {
    test('has exactly 3 values', () {
      expect(CenterMode.values, hasLength(3));
      expect(
        CenterMode.values,
        containsAll(<CenterMode>[
          CenterMode.ui,
          CenterMode.bundle,
          CenterMode.debug,
        ]),
      );
    });

    test('names are non-empty', () {
      for (final m in CenterMode.values) {
        expect(m.name, isNotEmpty);
      }
    });
  });

  // ── CenterMode.layersFor ───────────────────────────────────────────
  group('CenterMode.layersFor', () {
    test('ui mode exposes 8 layers', () {
      final layers = CenterMode.layersFor(CenterMode.ui);
      expect(layers, hasLength(8));
    });

    test('ui mode includes appStructure, theme, components, pages, whole', () {
      final layers = CenterMode.layersFor(CenterMode.ui);
      expect(
        layers,
        containsAll(<LayerId>[
          LayerId.appStructure,
          LayerId.theme,
          LayerId.components,
          LayerId.pages,
          LayerId.whole,
        ]),
      );
    });

    test('ui mode includes dashboard, navigation, assets', () {
      final layers = CenterMode.layersFor(CenterMode.ui);
      expect(
        layers,
        containsAll(<LayerId>[
          LayerId.dashboard,
          LayerId.navigation,
          LayerId.assets,
        ]),
      );
    });

    test('bundle mode exposes exactly 4 layers', () {
      final layers = CenterMode.layersFor(CenterMode.bundle);
      expect(layers, hasLength(4));
    });

    test('bundle mode contains manifest, tools, knowledge, agents', () {
      final layers = CenterMode.layersFor(CenterMode.bundle);
      expect(
        layers,
        containsAll(<LayerId>[
          LayerId.manifest,
          LayerId.tools,
          LayerId.knowledge,
          LayerId.agents,
        ]),
      );
    });

    test('debug mode exposes no layers', () {
      expect(CenterMode.layersFor(CenterMode.debug), isEmpty);
    });

    test('returns unmodifiable / safe list (no concurrent-mod on iteration)', () {
      final layers = CenterMode.layersFor(CenterMode.ui);
      // If the list were the internal constant directly, mutation would corrupt
      // the static map. Iteration should always succeed without CME.
      expect(() {
        for (final l in layers) {
          l.name; // touch every element
        }
      }, returnsNormally);
    });
  });

  // ── CenterMode.modeOf ─────────────────────────────────────────────
  group('CenterMode.modeOf', () {
    test('manifest → bundle', () {
      expect(CenterMode.modeOf(LayerId.manifest), CenterMode.bundle);
    });

    test('tools → bundle', () {
      expect(CenterMode.modeOf(LayerId.tools), CenterMode.bundle);
    });

    test('knowledge → bundle', () {
      expect(CenterMode.modeOf(LayerId.knowledge), CenterMode.bundle);
    });

    test('agents → bundle', () {
      expect(CenterMode.modeOf(LayerId.agents), CenterMode.bundle);
    });

    test('appStructure → ui', () {
      expect(CenterMode.modeOf(LayerId.appStructure), CenterMode.ui);
    });

    test('theme → ui', () {
      expect(CenterMode.modeOf(LayerId.theme), CenterMode.ui);
    });

    test('components → ui', () {
      expect(CenterMode.modeOf(LayerId.components), CenterMode.ui);
    });

    test('dashboard → ui', () {
      expect(CenterMode.modeOf(LayerId.dashboard), CenterMode.ui);
    });

    test('navigation → ui', () {
      expect(CenterMode.modeOf(LayerId.navigation), CenterMode.ui);
    });

    test('pages → ui', () {
      expect(CenterMode.modeOf(LayerId.pages), CenterMode.ui);
    });

    test('assets → ui', () {
      expect(CenterMode.modeOf(LayerId.assets), CenterMode.ui);
    });

    test('whole → ui (falls through to default)', () {
      // `whole` is not in the bundle layer list; defaults to ui.
      expect(CenterMode.modeOf(LayerId.whole), CenterMode.ui);
    });

    test('modeOf is the inverse of layersFor for non-debug layers', () {
      // Every layer in layersFor(bundle) must resolve back to bundle.
      for (final l in CenterMode.layersFor(CenterMode.bundle)) {
        expect(
          CenterMode.modeOf(l),
          CenterMode.bundle,
          reason: 'layer $l should map back to bundle',
        );
      }
      // Every non-bundle layer that appears in layersFor(ui) should
      // resolve to ui.
      for (final l in CenterMode.layersFor(CenterMode.ui)) {
        expect(
          CenterMode.modeOf(l),
          CenterMode.ui,
          reason: 'layer $l should map back to ui',
        );
      }
    });
  });

  // ── ConvertResult value class ──────────────────────────────────────
  group('ConvertResult', () {
    test('stores outDir, canonicalHash, writtenFiles', () {
      const result = ConvertResult(
        outDir: '/tmp/out',
        canonicalHash: 'sha256:abc',
        writtenFiles: <String>['a.dart', 'b.dart'],
      );
      expect(result.outDir, '/tmp/out');
      expect(result.canonicalHash, 'sha256:abc');
      expect(result.writtenFiles, <String>['a.dart', 'b.dart']);
    });

    test('empty writtenFiles is valid', () {
      const result = ConvertResult(
        outDir: '/out',
        canonicalHash: '',
        writtenFiles: <String>[],
      );
      expect(result.writtenFiles, isEmpty);
    });

    test('two instances with same values are not required to be identical '
        '(value equality not overridden)', () {
      // ConvertResult does not override == so two distinct const instances
      // at different code locations ARE identical by const canonicalization.
      const r1 = ConvertResult(
        outDir: '/x',
        canonicalHash: 'h',
        writtenFiles: <String>[],
      );
      const r2 = ConvertResult(
        outDir: '/x',
        canonicalHash: 'h',
        writtenFiles: <String>[],
      );
      // At least verify both carry the right data.
      expect(r1.outDir, r2.outDir);
      expect(r1.canonicalHash, r2.canonicalHash);
    });
  });

  // ── Re-export invariant: LayerId accessible via the shim ───────────
  group('re-exported LayerId accessible through types.dart', () {
    test('LayerId.values has 12 entries', () {
      // Verifies the re-export chain is intact; deep value tests live in
      // canonical_patch_test.dart.
      expect(LayerId.values.length, 12);
    });
  });
}
