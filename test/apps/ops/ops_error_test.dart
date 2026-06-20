/// OpsError — unit tests for toString formatting.
///
/// Pure Dart value type, no I/O.
///
/// Scenarios:
///   e1  toString with only code + message
///   e2  toString with detail appended
///   e3  toString with suggestion appended
///   e4  toString with both detail and suggestion
///   e5  code + message preserved verbatim on fields
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/config/ops_error.dart';

void main() {
  group('OpsError', () {
    // e1
    test('e1 toString with code + message only', () {
      final err = OpsError(code: 'E1001', message: 'Config read failed');
      final s = err.toString();
      expect(s, contains('E1001'));
      expect(s, contains('Config read failed'));
      expect(s, isNot(contains('Detail')));
      expect(s, isNot(contains('Suggestion')));
    });

    // e2
    test('e2 toString includes detail when present', () {
      final err = OpsError(
        code: 'E1002',
        message: 'YAML parse error',
        detail: 'line 4: unexpected ":"',
      );
      final s = err.toString();
      expect(s, contains('E1002'));
      expect(s, contains('YAML parse error'));
      expect(s, contains('Detail'));
      expect(s, contains('line 4: unexpected ":"'));
    });

    // e3
    test('e3 toString includes suggestion when present', () {
      final err = OpsError(
        code: 'E2001',
        message: 'API key missing',
        suggestion: 'Run config_set_llm_provider to add a key.',
      );
      final s = err.toString();
      expect(s, contains('E2001'));
      expect(s, contains('Suggestion'));
      expect(s, contains('Run config_set_llm_provider'));
    });

    // e4
    test('e4 toString includes both detail and suggestion', () {
      final err = OpsError(
        code: 'E3000',
        message: 'Workspace not found',
        detail: 'id=org/finance',
        suggestion: 'Create it with workspace_create.',
      );
      final s = err.toString();
      expect(s, contains('Detail'));
      expect(s, contains('org/finance'));
      expect(s, contains('Suggestion'));
      expect(s, contains('workspace_create'));
    });

    // e5
    test('e5 field values are preserved verbatim', () {
      const code = 'E9999';
      const message = 'test message';
      const detail = 'test detail';
      const suggestion = 'test suggestion';
      final err = OpsError(
        code: code,
        message: message,
        detail: detail,
        suggestion: suggestion,
      );
      expect(err.code, code);
      expect(err.message, message);
      expect(err.detail, detail);
      expect(err.suggestion, suggestion);
    });

    test('e6 OpsError is an Exception', () {
      final err = OpsError(code: 'X', message: 'y');
      expect(err, isA<Exception>());
    });
  });
}
