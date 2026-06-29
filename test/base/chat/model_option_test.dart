/// Unit tests for `VibeModelOption` + `kVibeModelCatalog` in `model_option.dart`.
///
/// Boot-independent: pure constant catalog.
///
/// Scenarios:
///   mo1  kVibeModelCatalog is non-empty
///   mo2  every entry has non-empty id and label
///   mo3  VibeModelOption.id / label / note / provider fields set correctly
///   mo4  VibeModelOption.note is null when not provided
///   mo5  VibeModelOption.provider is null when not provided
///   mo6  catalog contains claude-opus / claude-sonnet / claude-haiku entries
///   mo7  catalog entries are const (compile-time constant list)
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/chat/model_option.dart';

void main() {
  group('kVibeModelCatalog', () {
    // mo1
    test('mo1 catalog is non-empty', () {
      expect(kVibeModelCatalog, isNotEmpty);
    });

    // mo2
    test('mo2 every entry has non-empty id and label', () {
      for (final m in kVibeModelCatalog) {
        expect(m.id, isNotEmpty, reason: 'id must not be empty');
        expect(m.label, isNotEmpty, reason: '${m.id} label must not be empty');
      }
    });

    // mo6
    test('mo6 catalog contains claude-opus, claude-sonnet, claude-haiku', () {
      final ids = kVibeModelCatalog.map((m) => m.id).toList();
      expect(ids, contains('claude-opus-4-7'));
      expect(ids, contains('claude-sonnet-4-6'));
      expect(ids, contains('claude-haiku-4-5-20251001'));
    });
  });

  group('VibeModelOption', () {
    // mo3
    test('mo3 all constructor fields are preserved', () {
      const m = VibeModelOption(
        id: 'gpt-4o',
        label: 'GPT-4o',
        note: 'balanced flagship',
        provider: 'openai',
      );
      expect(m.id, 'gpt-4o');
      expect(m.label, 'GPT-4o');
      expect(m.note, 'balanced flagship');
      expect(m.provider, 'openai');
    });

    // mo4
    test('mo4 note is null when not provided', () {
      const m = VibeModelOption(id: 'test-id', label: 'Test');
      expect(m.note, isNull);
    });

    // mo5
    test('mo5 provider is null when not provided', () {
      const m = VibeModelOption(id: 'test-id', label: 'Test');
      expect(m.provider, isNull);
    });

    // mo7
    test('mo7 catalog entries carry non-null note (they all have notes)', () {
      // The current catalog entries all have notes. Verify the first entry.
      expect(kVibeModelCatalog.first.note, isNotNull);
    });

    test('mo — catalog first entry is the preferred model (claude-opus)', () {
      expect(kVibeModelCatalog.first.id, 'claude-opus-4-8');
    });
  });
}
