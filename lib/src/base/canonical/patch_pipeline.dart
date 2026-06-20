import 'package:brain_kernel/brain_kernel.dart'
    show
        PatchApplied,
        PatchRejected,
        PatchResult,
        ValidationReport,
        ValidationSeverity;

import '../spec/spec_validator.dart';
import '../types/canonical_patch.dart';
import 'workspace_canonical.dart';

/// Single entry point for canonical mutations. Runs a validator dry-run,
/// delegates the atomic write, notifies subscribers, and rolls back on
/// failure. Concrete implementations wire a [WorkspaceCanonical] and a
/// [SpecValidator].
abstract interface class PatchPipeline {
  Future<PatchResult> apply(CanonicalPatch patch);
}

/// Default implementation. See `core-patch-pipeline.md` (DDD).
class PatchPipelineImpl implements PatchPipeline {
  PatchPipelineImpl({
    required WorkspaceCanonical canonical,
    required SpecValidator validator,
  }) : _canonical = canonical,
       _validator = validator;

  final WorkspaceCanonical _canonical;
  final SpecValidator _validator;

  @override
  Future<PatchResult> apply(CanonicalPatch patch) async {
    if (patch.ops.isEmpty) {
      return const PatchApplied(
        changedPointers: <String>[],
        beforeHash: '',
        afterHash: '',
      );
    }
    final issues = _validator.dryRun(_canonical.current, patch);
    final errors = issues
        .where((i) => i.severity == ValidationSeverity.error)
        .toList(growable: false);
    if (errors.isNotEmpty) {
      final warnings = issues
          .where((i) => i.severity == ValidationSeverity.warning)
          .toList(growable: false);
      final infos = issues
          .where((i) => i.severity == ValidationSeverity.info)
          .toList(growable: false);
      return PatchRejected(
        report: ValidationReport(
          errors: errors,
          warnings: warnings,
          infos: infos,
        ),
      );
    }
    final beforeHash = await _canonical.hash();
    await _canonical.applyAtomic(patch);
    final afterHash = await _canonical.hash();
    final changedPointers = patch.ops
        .map((op) => op.path)
        .toList(growable: false);
    return PatchApplied(
      changedPointers: changedPointers,
      beforeHash: beforeHash,
      afterHash: afterHash,
    );
  }
}
