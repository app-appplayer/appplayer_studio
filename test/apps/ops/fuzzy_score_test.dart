/// Unit tests for `fuzzyScore` in `command_registry.dart`.
///
/// Boot-independent: pure string scoring function.
///
/// Scenarios:
///   fs1  empty query returns score 1.0 for any label
///   fs2  exact match returns score 100
///   fs3  prefix match returns score > 10 (≥ 50 band)
///   fs4  word-start match returns score > 10 (30 band)
///   fs5  substring-only match returns score > 0 (10 band)
///   fs6  no match returns null
///   fs7  case-insensitive matching (query upper vs label lower)
///   fs8  label is preserved verbatim in the result (not lowercased)
///   fs9  word boundary on hyphen separator
///   fs10 word boundary on underscore separator
///   fs11 word boundary on slash separator
///   fs12 word boundary on space separator
///   fs13 prefix match score includes fractional length ratio
///   fs14 exact full-word match not confused with prefix (exact wins)
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/core/command_registry.dart';

void main() {
  group('fuzzyScore', () {
    // fs1
    test('fs1 empty query returns (score:1.0, label:label) for any label', () {
      final r = fuzzyScore('', 'Hello World');
      expect(r, isNotNull);
      expect(r!.score, 1.0);
      expect(r.label, 'Hello World');
    });

    test('fs1b empty query empty label still returns a result', () {
      final r = fuzzyScore('', '');
      expect(r, isNotNull);
      expect(r!.score, 1.0);
    });

    // fs2
    test('fs2 exact match returns score 100', () {
      final r = fuzzyScore('home', 'home');
      expect(r, isNotNull);
      expect(r!.score, 100);
    });

    test('fs2b exact match is case-insensitive', () {
      final r = fuzzyScore('HOME', 'home');
      expect(r, isNotNull);
      expect(r!.score, 100);
    });

    // fs3
    test('fs3 prefix match returns score >= 50', () {
      final r = fuzzyScore('ho', 'home');
      expect(r, isNotNull);
      expect(r!.score, greaterThanOrEqualTo(50));
    });

    test('fs3b prefix match returns lower score than exact', () {
      final prefix = fuzzyScore('ho', 'home')!.score;
      final exact = fuzzyScore('home', 'home')!.score;
      expect(prefix, lessThan(exact));
    });

    // fs4
    test('fs4 word-start match (space separator) returns score in 30 band', () {
      final r = fuzzyScore('wo', 'Hello World');
      expect(r, isNotNull);
      // 'wo' starts word 'world' → word-boundary → score in 30+ band, < 50
      expect(r!.score, greaterThanOrEqualTo(30));
      expect(r.score, lessThan(50));
    });

    // fs5
    test('fs5 substring-only match returns score in 10 band', () {
      // 'ell' is a substring of 'Hello' but not a prefix or word start
      final r = fuzzyScore('ell', 'Hello');
      expect(r, isNotNull);
      expect(r!.score, greaterThanOrEqualTo(10));
      expect(r.score, lessThan(30));
    });

    // fs6
    test('fs6 no match returns null', () {
      expect(fuzzyScore('xyz', 'Hello World'), isNull);
      expect(fuzzyScore('zzz', 'abcdef'), isNull);
    });

    // fs7
    test('fs7 matching is case-insensitive', () {
      expect(fuzzyScore('ACTIVITY', 'Activity'), isNotNull);
      expect(fuzzyScore('activity', 'ACTIVITY'), isNotNull);
    });

    // fs8
    test('fs8 label is returned verbatim (not lowercased)', () {
      final r = fuzzyScore('act', 'Activity Feed');
      expect(r, isNotNull);
      expect(r!.label, 'Activity Feed');
    });

    // fs9
    test('fs9 word boundary on hyphen', () {
      // 'bu' matches word start of 'builder' in 'app-builder'
      final r = fuzzyScore('bu', 'app-builder');
      expect(r, isNotNull);
      expect(r!.score, greaterThanOrEqualTo(30));
      expect(r.score, lessThan(50));
    });

    // fs10
    test('fs10 word boundary on underscore', () {
      // 'bu' matches word start of 'builder' in 'app_builder'
      final r = fuzzyScore('bu', 'app_builder');
      expect(r, isNotNull);
      expect(r!.score, greaterThanOrEqualTo(30));
      expect(r.score, lessThan(50));
    });

    // fs11
    test('fs11 word boundary on slash', () {
      // 'bu' matches word start of 'builder' in 'app/builder'
      final r = fuzzyScore('bu', 'app/builder');
      expect(r, isNotNull);
      expect(r!.score, greaterThanOrEqualTo(30));
      expect(r.score, lessThan(50));
    });

    // fs12
    test('fs12 word boundary on space', () {
      final r = fuzzyScore('kn', 'Go to Knowledge');
      expect(r, isNotNull);
      expect(r!.score, greaterThanOrEqualTo(30));
    });

    // fs13
    test(
      'fs13 prefix score includes fractional ratio — shorter prefix scores lower',
      () {
        // 'h' prefix of 'home' vs 'ho' prefix — 'ho' has higher ratio
        final short = fuzzyScore('h', 'home')!.score;
        final long = fuzzyScore('ho', 'home')!.score;
        expect(long, greaterThan(short));
      },
    );

    // fs14
    test('fs14 exact wins over prefix in scoring', () {
      final exact = fuzzyScore('home', 'home')!.score;
      final prefix = fuzzyScore('home', 'homepage')!.score;
      expect(exact, greaterThan(prefix));
    });

    test('fs — single char matching exact single-char label', () {
      final r = fuzzyScore('a', 'a');
      expect(r, isNotNull);
      expect(r!.score, 100);
    });

    test('fs — returns null for empty label vs non-empty query', () {
      expect(fuzzyScore('x', ''), isNull);
    });
  });
}
