/// Unit tests for `app_builder/core/patch_pipeline.dart`.
///
/// The file is a re-export shim; the real logic lives in
/// `base/canonical/patch_pipeline.dart` (PatchPipelineImpl). Tests use
/// stub implementations of WorkspaceCanonical and SpecValidator so they
/// run without a kernel boot.
///
/// Covered branches:
///   p1 — empty ops → PatchApplied with empty changedPointers.
///   p2 — validator passes → PatchApplied with op paths in changedPointers.
///   p3 — validator returns error(s) → PatchRejected with report.
///   p4 — changedPointers match the op paths from the patch.
///   p5 — multiple ops → all paths appear in changedPointers.
///   p6 — hash before/after populated from canonical.hash().
library;

import 'dart:async';

import 'package:brain_kernel/brain_kernel.dart'
    show
        CanonicalChange,
        McpBundle,
        ValidationIssue,
        ValidationLayer,
        ValidationSeverity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' show BundleManifest;
import 'package:appplayer_studio/base.dart'
    show
        CanonicalPatch,
        ImportKind,
        LayerId,
        PatchPipeline,
        PatchPipelineImpl,
        SpecValidator,
        UndoState,
        WorkspaceCanonical;
import 'package:appplayer_studio/builtin_api.dart'
    show PatchApplied, PatchOp, PatchRejected, UserOriginator;

// ── stub WorkspaceCanonical ────────────────────────────────────────────
class _StubCanonical implements WorkspaceCanonical {
  _StubCanonical({String hash = 'sha256:before'}) : _hash = hash;

  int applyCount = 0;
  String _hash;

  @override
  McpBundle get current => McpBundle(
    manifest: BundleManifest(id: 'test', name: 'Test Bundle', version: '0.1.0'),
  );

  @override
  Map<String, dynamic> get currentJson => <String, dynamic>{};

  @override
  Future<String> hash() async => _hash;

  @override
  Future<void> applyAtomic(CanonicalPatch patch) async {
    applyCount++;
    _hash = 'sha256:after';
  }

  // ── unused members — must satisfy the interface ────────────────────
  @override
  Future<McpBundle> open(String workspacePath) => throw UnimplementedError();

  @override
  Future<McpBundle> import({
    required String source,
    required ImportKind kind,
  }) => throw UnimplementedError();

  @override
  Future<void> save() => throw UnimplementedError();

  @override
  Future<void> saveAs(String newPath) => throw UnimplementedError();

  @override
  Future<void> revert() => throw UnimplementedError();

  @override
  Future<bool> undo() => throw UnimplementedError();

  @override
  Future<bool> redo() => throw UnimplementedError();

  @override
  bool get canUndo => false;

  @override
  bool get canRedo => false;

  @override
  Stream<UndoState> get undoStateChanges => const Stream.empty();

  @override
  List<Map<String, dynamic>> get undoStackJson => const [];

  @override
  List<Map<String, dynamic>> get redoStackJson => const [];

  @override
  void seedUndoStacks({
    required List<Map<String, dynamic>> undo,
    required List<Map<String, dynamic>> redo,
  }) {}

  @override
  bool get isDirty => false;

  @override
  bool get hasRestoredDraft => false;

  @override
  Stream<bool> get dirtyChanges => const Stream.empty();

  @override
  Stream<CanonicalChange> get changes => const Stream.empty();

  @override
  String? get committedHash => null;

  @override
  String? get workspacePath => null;
}

// ── stub SpecValidator ─────────────────────────────────────────────────
class _StubValidator implements SpecValidator {
  _StubValidator({List<ValidationIssue> issues = const []}) : _issues = issues;

  final List<ValidationIssue> _issues;

  @override
  List<ValidationIssue> validateFull(McpBundle bundle) => _issues;

  @override
  List<ValidationIssue> dryRun(McpBundle bundle, CanonicalPatch patch) =>
      _issues;
}

// ── helpers ────────────────────────────────────────────────────────────
ValidationIssue _error(String code) => ValidationIssue(
  severity: ValidationSeverity.error,
  code: code,
  pointer: '/x',
  message: 'error: $code',
  layer: ValidationLayer.schema,
);

ValidationIssue _warning(String code) => ValidationIssue(
  severity: ValidationSeverity.warning,
  code: code,
  pointer: '/x',
  message: 'warn: $code',
  layer: ValidationLayer.schema,
);

CanonicalPatch _patch(List<PatchOp> ops) => CanonicalPatch(
  layer: LayerId.pages,
  ops: ops,
  originator: const UserOriginator(),
);

PatchOp _op(String path) => PatchOp(op: 'add', path: path, value: 'v');

// ── tests ──────────────────────────────────────────────────────────────
void main() {
  group('PatchPipelineImpl construction', () {
    test('implements PatchPipeline', () {
      final pipe = PatchPipelineImpl(
        canonical: _StubCanonical(),
        validator: _StubValidator(),
      );
      expect(pipe, isA<PatchPipeline>());
    });
  });

  group('p1 — empty ops yields PatchApplied with empty changedPointers', () {
    test('returns PatchApplied', () async {
      final pipe = PatchPipelineImpl(
        canonical: _StubCanonical(),
        validator: _StubValidator(),
      );
      final result = await pipe.apply(_patch(const <PatchOp>[]));
      expect(result, isA<PatchApplied>());
    });

    test('changedPointers is empty', () async {
      final pipe = PatchPipelineImpl(
        canonical: _StubCanonical(),
        validator: _StubValidator(),
      );
      final result =
          await pipe.apply(_patch(const <PatchOp>[])) as PatchApplied;
      expect(result.changedPointers, isEmpty);
    });

    test('beforeHash and afterHash are both empty strings', () async {
      final pipe = PatchPipelineImpl(
        canonical: _StubCanonical(),
        validator: _StubValidator(),
      );
      final result =
          await pipe.apply(_patch(const <PatchOp>[])) as PatchApplied;
      expect(result.beforeHash, '');
      expect(result.afterHash, '');
    });

    test('applyAtomic on canonical is NOT called for empty ops', () async {
      final canonical = _StubCanonical();
      final pipe = PatchPipelineImpl(
        canonical: canonical,
        validator: _StubValidator(),
      );
      await pipe.apply(_patch(const <PatchOp>[]));
      expect(canonical.applyCount, 0);
    });
  });

  group('p2 — validator passes → PatchApplied', () {
    test('single op: PatchApplied returned', () async {
      final pipe = PatchPipelineImpl(
        canonical: _StubCanonical(),
        validator: _StubValidator(),
      );
      final result = await pipe.apply(_patch(<PatchOp>[_op('/ui/title')]));
      expect(result, isA<PatchApplied>());
    });

    test('applyAtomic on canonical IS called', () async {
      final canonical = _StubCanonical();
      final pipe = PatchPipelineImpl(
        canonical: canonical,
        validator: _StubValidator(),
      );
      await pipe.apply(_patch(<PatchOp>[_op('/ui/title')]));
      expect(canonical.applyCount, 1);
    });
  });

  group('p3 — validator error → PatchRejected', () {
    test('returns PatchRejected', () async {
      final pipe = PatchPipelineImpl(
        canonical: _StubCanonical(),
        validator: _StubValidator(issues: <ValidationIssue>[_error('E001')]),
      );
      final result = await pipe.apply(_patch(<PatchOp>[_op('/ui/title')]));
      expect(result, isA<PatchRejected>());
    });

    test('report carries the error code', () async {
      final pipe = PatchPipelineImpl(
        canonical: _StubCanonical(),
        validator: _StubValidator(issues: <ValidationIssue>[_error('E001')]),
      );
      final result =
          await pipe.apply(_patch(<PatchOp>[_op('/x')])) as PatchRejected;
      expect(result.report.errors.map((e) => e.code), contains('E001'));
    });

    test('applyAtomic is NOT called on rejection', () async {
      final canonical = _StubCanonical();
      final pipe = PatchPipelineImpl(
        canonical: canonical,
        validator: _StubValidator(issues: <ValidationIssue>[_error('E001')]),
      );
      await pipe.apply(_patch(<PatchOp>[_op('/x')]));
      expect(canonical.applyCount, 0);
    });

    test('warnings alone do not cause rejection', () async {
      final pipe = PatchPipelineImpl(
        canonical: _StubCanonical(),
        validator: _StubValidator(issues: <ValidationIssue>[_warning('W001')]),
      );
      final result = await pipe.apply(_patch(<PatchOp>[_op('/ui/title')]));
      expect(result, isA<PatchApplied>());
    });

    test('report warnings and infos lists are separate from errors', () async {
      final pipe = PatchPipelineImpl(
        canonical: _StubCanonical(),
        validator: _StubValidator(
          issues: <ValidationIssue>[_error('E001'), _warning('W001')],
        ),
      );
      final result =
          await pipe.apply(_patch(<PatchOp>[_op('/x')])) as PatchRejected;
      expect(result.report.errors, hasLength(1));
      expect(result.report.warnings, hasLength(1));
      expect(result.report.infos, isEmpty);
    });
  });

  group('p4 — changedPointers match op paths', () {
    test('single op path appears in changedPointers', () async {
      final pipe = PatchPipelineImpl(
        canonical: _StubCanonical(),
        validator: _StubValidator(),
      );
      final result =
          await pipe.apply(_patch(<PatchOp>[_op('/ui/title')])) as PatchApplied;
      expect(result.changedPointers, contains('/ui/title'));
    });
  });

  group('p5 — multiple ops → all paths in changedPointers', () {
    test('two ops produce two changedPointers', () async {
      final pipe = PatchPipelineImpl(
        canonical: _StubCanonical(),
        validator: _StubValidator(),
      );
      final result =
          await pipe.apply(
                _patch(<PatchOp>[_op('/ui/title'), _op('/ui/routes/~1home')]),
              )
              as PatchApplied;
      expect(result.changedPointers, hasLength(2));
      expect(
        result.changedPointers,
        containsAll(<String>['/ui/title', '/ui/routes/~1home']),
      );
    });
  });

  group('p6 — hash fields populated', () {
    test('beforeHash is the pre-apply hash from canonical', () async {
      final canonical = _StubCanonical(hash: 'sha256:initial');
      final pipe = PatchPipelineImpl(
        canonical: canonical,
        validator: _StubValidator(),
      );
      final result =
          await pipe.apply(_patch(<PatchOp>[_op('/ui/title')])) as PatchApplied;
      expect(result.beforeHash, 'sha256:initial');
    });

    test(
      'afterHash differs from beforeHash after canonical.applyAtomic',
      () async {
        final canonical = _StubCanonical(hash: 'sha256:initial');
        final pipe = PatchPipelineImpl(
          canonical: canonical,
          validator: _StubValidator(),
        );
        final result =
            await pipe.apply(_patch(<PatchOp>[_op('/ui/title')]))
                as PatchApplied;
        expect(result.afterHash, 'sha256:after');
        expect(result.afterHash, isNot(result.beforeHash));
      },
    );
  });
}
