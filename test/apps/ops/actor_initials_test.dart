/// Unit tests for `ActivityActor.initials` (UX audit P3.11) — the avatar
/// monogram rule. A Latin+CJK mash (first letter of a Latin name plus the first
/// syllable of a CJK role) read as broken; the rule now builds a two-letter
/// monogram only from ASCII names and otherwise uses one grapheme.
///
/// Scenarios:
///   ai1  single word → first letter, upper-cased
///   ai2  two ASCII words → two-letter monogram ("John Doe" → "JD")
///   ai3  Latin + CJK -> single leading grapheme (no mixed-script pair)
///   ai4  CJK only → first syllable
///   ai5  empty / whitespace → "?"
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/widgets/ops_models.dart';

String _initials(String label) =>
    ActivityActor(kind: ActorKind.agent, label: label).initials;

void main() {
  group('ActivityActor.initials', () {
    test('ai1 single word → first letter upper', () {
      expect(_initials('Leo'), 'L');
      expect(_initials('aria'), 'A');
    });

    test('ai2 two ASCII words → two-letter monogram', () {
      expect(_initials('John Doe'), 'JD');
      expect(_initials('kai park'), 'KP');
    });

    test('ai3 Latin + CJK → single leading grapheme, not "Z담"', () {
      expect(_initials('Zara 담당'), 'Z');
      expect(_initials('Finn 담당'), 'F');
    });

    test('ai4 CJK only → first syllable', () {
      expect(_initials('재무 담당'), '재');
    });

    test('ai5 empty / whitespace → "?"', () {
      expect(_initials(''), '?');
      expect(_initials('   '), '?');
    });
  });
}
