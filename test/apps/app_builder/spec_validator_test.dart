/// Unit tests for `app_builder/core/spec_validator.dart`.
///
/// The file is a re-export shim; the real logic lives in
/// `base/spec/spec_validator.dart` (SpecValidatorImpl). Tests exercise:
///   - validateFull: MANIFEST_NAME_EMPTY, MANIFEST_ID_EMPTY,
///     clean bundle → empty issues.
///   - dryRun: delegates to validateFull (same outcomes for now).
///   - specVersion default: matches `spec_catalog.specSeriesVersion`.
///   - custom specVersion accepted (metadata only).
library;

import 'package:brain_kernel/brain_kernel.dart'
    show McpBundle, ValidationSeverity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' show BundleManifest;
import 'package:appplayer_studio/base.dart'
    show CanonicalPatch, LayerId, SpecValidator, SpecValidatorImpl;
import 'package:appplayer_studio/builtin_api.dart' show PatchOp, UserOriginator;
import 'package:appplayer_studio/src/base/spec/spec_catalog.dart'
    show specSeriesVersion;

McpBundle _bundle({String id = 'my_app', String name = 'My App'}) =>
    McpBundle(manifest: BundleManifest(id: id, name: name, version: '1.0.0'));

CanonicalPatch _noop() => const CanonicalPatch(
  layer: LayerId.pages,
  ops: <PatchOp>[],
  originator: UserOriginator(),
);

void main() {
  group('SpecValidatorImpl construction', () {
    test('default specVersion equals specSeriesVersion', () {
      final v = SpecValidatorImpl();
      expect(v.specVersion, specSeriesVersion);
      expect(v.specVersion, isNotEmpty);
    });

    test('custom specVersion is accepted', () {
      final v = SpecValidatorImpl(specVersion: '9.9');
      expect(v.specVersion, '9.9');
    });

    test('SpecValidatorImpl is a SpecValidator', () {
      expect(SpecValidatorImpl(), isA<SpecValidator>());
    });
  });

  group('validateFull', () {
    late SpecValidatorImpl validator;
    setUp(() => validator = SpecValidatorImpl());

    test('clean bundle → no error issues', () {
      final issues = validator.validateFull(_bundle());
      final errors = issues.where(
        (i) => i.severity == ValidationSeverity.error,
      );
      expect(
        errors,
        isEmpty,
        reason: 'a well-formed bundle should have no errors',
      );
    });

    test('empty manifest.name → MANIFEST_NAME_EMPTY error', () {
      final bundle = _bundle(name: '');
      final issues = validator.validateFull(bundle);
      final codes = issues
          .where((i) => i.severity == ValidationSeverity.error)
          .map((i) => i.code);
      expect(codes, contains('MANIFEST_NAME_EMPTY'));
    });

    test('MANIFEST_NAME_EMPTY pointer is /manifest/name', () {
      final bundle = _bundle(name: '');
      final issue = validator
          .validateFull(bundle)
          .firstWhere((i) => i.code == 'MANIFEST_NAME_EMPTY');
      expect(issue.pointer, '/manifest/name');
    });

    test('empty manifest.id → MANIFEST_ID_EMPTY error', () {
      final bundle = _bundle(id: '');
      final issues = validator.validateFull(bundle);
      final codes = issues
          .where((i) => i.severity == ValidationSeverity.error)
          .map((i) => i.code);
      expect(codes, contains('MANIFEST_ID_EMPTY'));
    });

    test('MANIFEST_ID_EMPTY pointer is /manifest/id', () {
      final bundle = _bundle(id: '');
      final issue = validator
          .validateFull(bundle)
          .firstWhere((i) => i.code == 'MANIFEST_ID_EMPTY');
      expect(issue.pointer, '/manifest/id');
    });

    test('both empty name AND id yield two custom errors', () {
      final bundle = _bundle(id: '', name: '');
      final issues = validator.validateFull(bundle);
      final codes =
          issues
              .where((i) => i.severity == ValidationSeverity.error)
              .map((i) => i.code)
              .toList();
      expect(
        codes,
        containsAll(<String>['MANIFEST_NAME_EMPTY', 'MANIFEST_ID_EMPTY']),
      );
    });

    test('issues are ValidationIssue objects with non-empty messages', () {
      final bundle = _bundle(name: '');
      final issues = validator.validateFull(bundle);
      expect(issues.isNotEmpty, isTrue);
      for (final i in issues) {
        expect(i.message, isNotEmpty);
      }
    });
  });

  group('dryRun', () {
    late SpecValidatorImpl validator;
    setUp(() => validator = SpecValidatorImpl());

    test('dryRun on clean bundle → no errors', () {
      final issues = validator.dryRun(_bundle(), _noop());
      final errors = issues.where(
        (i) => i.severity == ValidationSeverity.error,
      );
      expect(errors, isEmpty);
    });

    test('dryRun on invalid bundle returns same errors as validateFull', () {
      final bundle = _bundle(name: '');
      final patch = _noop();
      final dryIssues = validator.dryRun(bundle, patch);
      final fullIssues = validator.validateFull(bundle);
      expect(dryIssues.length, fullIssues.length);
      final dryCodes = dryIssues.map((i) => i.code).toSet();
      final fullCodes = fullIssues.map((i) => i.code).toSet();
      expect(dryCodes, equals(fullCodes));
    });

    test(
      'patch content has no effect on dryRun outcome (pure validateFull)',
      () {
        final bundle = _bundle();
        final patchWithOps = CanonicalPatch(
          layer: LayerId.pages,
          ops: <PatchOp>[
            PatchOp(
              op: 'add',
              path: '/ui/routes/~1new',
              value: 'ui://pages/new',
            ),
          ],
          originator: const UserOriginator(),
        );
        final issuesEmpty = validator.dryRun(bundle, _noop());
        final issuesWithOps = validator.dryRun(bundle, patchWithOps);
        expect(issuesEmpty.length, issuesWithOps.length);
      },
    );
  });
}
