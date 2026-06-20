/// Barrel for the built-in App Builder.
///
/// Exposes:
///
/// * [AppBuilderBuiltInApp] — the [BuiltInApp] implementation the host
///   discovers through [BuiltInAppRegistry] (no direct mount call
///   needed). Owns the chrome-action registration onto the host's
///   `ChromeBridge.headerActions` notifier and mounts [VibeShell].
/// * Editing-model types (canonical / pipeline / projection / project
///   / spec validator) are re-exported so future host code that wants
///   to drive the same model (e.g. preview embed, telemetry) can
///   reach them without depending on internal paths. The widget set
///   (`feat/`) intentionally stays private; chrome integration goes
///   through [AppBuilderBuiltInApp].
library;

// Core editing model — used by the built-in app and any host code that
// wants to observe / drive the same canonical from the outside.
export 'core/types.dart';
export 'core/workspace_canonical.dart';
export 'core/patch_pipeline.dart';
export 'core/layer_projection.dart';
export 'core/vibe_project.dart';
export 'core/spec_validator.dart';

// Infra primitives the editor expects to receive from the host.
export 'infra/vibe_settings.dart';
export 'infra/vibe_server_bridge.dart';

// Theme tokens — kept available so adapters can reuse the same palette
// inside chrome slots until chrome tokens take over.
export 'theme/tokens.dart';

// Built-in app implementation — the host doesn't import this directly;
// `registerBuiltInApps()` in `builtin_app_registry_bootstrap.dart`
// wires it into [BuiltInAppRegistry]. Exported here so tests / tooling
// can introspect.
export 'app_builder_builtin.dart';
