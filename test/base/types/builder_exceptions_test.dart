/// Unit coverage for `builder_exceptions.dart` — exception classes,
/// ImportKind enum, and ConvertResult value class.
library;

import 'package:brain_kernel/brain_kernel.dart'
    show ValidationIssue, ValidationLayer, ValidationSeverity;
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

void main() {
  // ---------------------------------------------------------------------------
  // DiskException
  // ---------------------------------------------------------------------------
  group('DiskException', () {
    test('toString includes class name and message', () {
      final ex = DiskException('write failed: ENOENT');
      expect('$ex', contains('DiskException'));
      expect('$ex', contains('write failed: ENOENT'));
    });

    test('is an Exception', () {
      expect(DiskException('x'), isA<Exception>());
    });

    test('can be caught as Exception', () {
      expect(() => throw DiskException('oops'), throwsA(isA<DiskException>()));
    });
  });

  // ---------------------------------------------------------------------------
  // LoadException
  // ---------------------------------------------------------------------------
  group('LoadException', () {
    test('toString format', () {
      final ex = LoadException('missing manifest.json');
      expect('$ex', contains('LoadException'));
      expect('$ex', contains('missing manifest.json'));
    });

    test('caught as Exception', () {
      expect(
        () => throw LoadException('bad json'),
        throwsA(isA<LoadException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // ImportException
  // ---------------------------------------------------------------------------
  group('ImportException', () {
    test('toString format', () {
      final ex = ImportException('kind mismatch');
      expect('$ex', contains('ImportException'));
      expect('$ex', contains('kind mismatch'));
    });
  });

  // ---------------------------------------------------------------------------
  // ValidationException
  // ---------------------------------------------------------------------------
  group('ValidationException', () {
    test('toString reports issue count', () {
      final issues = <ValidationIssue>[
        const ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'missing',
          message: 'required',
          layer: ValidationLayer.schema,
          pointer: '/name',
        ),
        const ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'missing',
          message: 'required',
          layer: ValidationLayer.schema,
          pointer: '/id',
        ),
      ];
      final ex = ValidationException(issues);
      expect('$ex', contains('ValidationException'));
      expect('$ex', contains('2'));
    });

    test('issues list is accessible', () {
      final issues = <ValidationIssue>[
        const ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'invalid',
          message: 'bad',
          layer: ValidationLayer.schema,
          pointer: '/x',
        ),
      ];
      final ex = ValidationException(issues);
      expect(ex.issues, same(issues));
    });
  });

  // ---------------------------------------------------------------------------
  // ImportKind enum
  // ---------------------------------------------------------------------------
  group('ImportKind', () {
    test('has mbd and mcpb values', () {
      expect(ImportKind.values, hasLength(2));
      expect(
        ImportKind.values,
        containsAll(<ImportKind>[ImportKind.mbd, ImportKind.mcpb]),
      );
    });

    test('names are stable', () {
      expect(ImportKind.mbd.name, 'mbd');
      expect(ImportKind.mcpb.name, 'mcpb');
    });
  });

  // ---------------------------------------------------------------------------
  // ConvertResult
  // ---------------------------------------------------------------------------
  group('ConvertResult', () {
    test('stores all three fields', () {
      const r = ConvertResult(
        outDir: '/tmp/build',
        canonicalHash: 'abc123',
        writtenFiles: <String>['manifest.json', 'ui/app.json'],
      );
      expect(r.outDir, '/tmp/build');
      expect(r.canonicalHash, 'abc123');
      expect(r.writtenFiles, hasLength(2));
      expect(r.writtenFiles, contains('manifest.json'));
    });

    test('is immutable (@immutable annotation — const construction works)', () {
      const r1 = ConvertResult(
        outDir: '/a',
        canonicalHash: 'h1',
        writtenFiles: <String>[],
      );
      const r2 = ConvertResult(
        outDir: '/b',
        canonicalHash: 'h2',
        writtenFiles: <String>['x'],
      );
      expect(r1.outDir, isNot(r2.outDir));
    });
  });
}
