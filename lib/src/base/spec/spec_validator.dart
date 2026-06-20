import 'package:brain_kernel/brain_kernel.dart'
    as mb
    show McpBundle, McpBundleValidator;
import 'package:brain_kernel/brain_kernel.dart'
    show ValidationIssue, ValidationLayer, ValidationSeverity;

import '../types/canonical_patch.dart';
import 'spec_catalog.dart' as sc;

/// Validates a [mb.McpBundle] against the mcp_ui DSL spec and runs
/// dry-run checks for prospective patches.
abstract interface class SpecValidator {
  List<ValidationIssue> validateFull(mb.McpBundle bundle);
  List<ValidationIssue> dryRun(mb.McpBundle bundle, CanonicalPatch patch);
}

/// Default implementation. Delegates structural checks to mcp_bundle's
/// `McpBundleValidator` and surfaces them as [ValidationIssue]s.
///
/// `specVersion` is metadata only — `McpBundleValidator.validate` does
/// not branch on it. Default reads from `spec_catalog.specSeriesVersion`
/// (the 2-part schema-series form derived from the canonical revision)
/// so the validator stays in lock step with the schema directory and
/// `$id` URL prefix the catalog uses. UI surfaces still pass the full
/// revision when they want it displayed.
class SpecValidatorImpl implements SpecValidator {
  SpecValidatorImpl({String? specVersion})
    : specVersion = specVersion ?? sc.specSeriesVersion;
  final String specVersion;

  @override
  List<ValidationIssue> validateFull(mb.McpBundle bundle) {
    final issues = <ValidationIssue>[];
    if (bundle.manifest.name.isEmpty) {
      issues.add(
        const ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'MANIFEST_NAME_EMPTY',
          pointer: '/manifest/name',
          message: 'manifest.name must be non-empty',
          layer: ValidationLayer.schema,
        ),
      );
    }
    if (bundle.manifest.id.isEmpty) {
      issues.add(
        const ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'MANIFEST_ID_EMPTY',
          pointer: '/manifest/id',
          message: 'manifest.id must be non-empty',
          layer: ValidationLayer.schema,
        ),
      );
    }
    final result = mb.McpBundleValidator.validate(bundle);
    for (final e in result.errors) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: e.code,
          pointer: e.location,
          message: e.message,
          layer: ValidationLayer.schema,
        ),
      );
    }
    for (final w in result.warnings) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          code: w.code,
          pointer: w.location,
          message: w.message,
          layer: ValidationLayer.schema,
        ),
      );
    }
    return issues;
  }

  @override
  List<ValidationIssue> dryRun(mb.McpBundle bundle, CanonicalPatch patch) {
    return validateFull(bundle);
  }
}
