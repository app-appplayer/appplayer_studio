// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/builder_mutator/lib/builder_ui_types.dart
// Regenerate with debug/tool/sync_builder_mutator_fork.sh.
//
/// Seams of the atomic `studio.builder.ui.*` tools.
///
/// The tools read and write a bundle's `ui/app.json` and touch nothing
/// else. Two things depend on the host and are injected: which bundle to
/// use when a caller omits `mbdPath`, and whether a node is checked against
/// the widget catalogue before it is written.
library;

/// Resolves the active project's `.mbd` path when a tool's caller omits
/// `mbdPath`. A host without an active project passes none, and then
/// `mbdPath` is required.
typedef ActiveMbdResolver = String? Function();

/// Outcome of a node check: [ok], or a [rejection] in the diagnostic shape
/// (`code` / `path?` / `expected?` / `actual?` / `message` / `suggestion?`).
abstract class UiValidation {
  bool get ok;
  Map<String, dynamic>? get rejection;
}

/// Checks a widget node (or one of its props) against the widget catalogue
/// before it is written. Optional: without one the tools still check paths
/// and structure, but not the widget type, props or enum values.
abstract class UiNodeValidator {
  Future<UiValidation> validateNode(Object? node);

  Future<UiValidation> validateProp({
    required String type,
    required String key,
    required Object? value,
  });
}
