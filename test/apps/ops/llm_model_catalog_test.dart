/// Unit tests for `llm_model_catalog.dart` — provider lookup helpers.
///
/// Boot-independent: pure constant data + lookup functions.
///
/// Scenarios:
///   lm1  kLlmProviderCatalog — contains at least claude and openai
///   lm2  findProviderOption — known provider returns correct option
///   lm3  findProviderOption — empty id returns null
///   lm4  findProviderOption — unknown id returns null
///   lm5  findProviderOption — 'stub' returns kStubProviderOption
///   lm6  findModelOption — known (provider, model) pair returns option
///   lm7  findModelOption — unknown provider returns null
///   lm8  findModelOption — unknown model id returns null
///   lm9  LlmProviderOption.defaultModel — first model in list
///   lm10 kCustomModelOption id is '__custom__'
///   lm11 all models in catalog have non-empty id and label
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/util/llm_model_catalog.dart';

void main() {
  group('LlmModelCatalog', () {
    // lm1
    test('lm1 catalog contains claude and openai', () {
      final ids = kLlmProviderCatalog.map((p) => p.id).toList();
      expect(ids, contains('claude'));
      expect(ids, contains('openai'));
    });

    // lm2
    test('lm2 findProviderOption returns correct provider for claude', () {
      final opt = findProviderOption('claude');
      expect(opt, isNotNull);
      expect(opt!.id, 'claude');
      expect(opt.label, isNotEmpty);
      expect(opt.models, isNotEmpty);
    });

    // lm3
    test('lm3 findProviderOption returns null for empty id', () {
      expect(findProviderOption(''), isNull);
    });

    // lm4
    test('lm4 findProviderOption returns null for unknown id', () {
      expect(findProviderOption('nonexistent_llm_xyz'), isNull);
    });

    // lm5
    test('lm5 findProviderOption returns kStubProviderOption for stub', () {
      final opt = findProviderOption('stub');
      expect(opt, isNotNull);
      expect(opt!.id, 'stub');
      expect(identical(opt, kStubProviderOption), isTrue);
    });

    // lm6
    test('lm6 findModelOption returns correct model for known pair', () {
      final m = findModelOption('claude', 'claude-sonnet-4-6');
      expect(m, isNotNull);
      expect(m!.id, 'claude-sonnet-4-6');
      expect(m.label, isNotEmpty);
    });

    // lm7
    test('lm7 findModelOption returns null for unknown provider', () {
      expect(findModelOption('phantom', 'model-1'), isNull);
    });

    // lm8
    test('lm8 findModelOption returns null for unknown model id', () {
      expect(findModelOption('claude', 'claude-9000-ultra'), isNull);
    });

    // lm9
    test('lm9 defaultModel is the first model in the list', () {
      final provider = findProviderOption('openai')!;
      expect(provider.defaultModel.id, provider.models.first.id);
    });

    // lm10
    test('lm10 kCustomModelOption id is __custom__', () {
      expect(kCustomModelOption.id, '__custom__');
      expect(kCustomModelOption.label, isNotEmpty);
    });

    // lm11
    test('lm11 all catalog models have non-empty id and label', () {
      for (final provider in kLlmProviderCatalog) {
        expect(
          provider.id,
          isNotEmpty,
          reason: 'provider id must not be empty',
        );
        for (final model in provider.models) {
          expect(
            model.id,
            isNotEmpty,
            reason: '${provider.id} model id must not be empty',
          );
          expect(
            model.label,
            isNotEmpty,
            reason: '${provider.id}/${model.id} label must not be empty',
          );
        }
      }
    });

    test('lm — openai has at least one model', () {
      final opt = findProviderOption('openai')!;
      expect(opt.models, isNotEmpty);
    });
  });
}
