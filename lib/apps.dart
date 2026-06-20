/// Public API surface for the vibe_studio built-in apps area.
///
/// Each built-in app re-exports its public types through a single barrel
/// (e.g. `src/apps/app_builder/app_builder.dart`). The barrel files keep
/// vibe_studio host code (workspace / chrome) from reaching into internal
/// source layouts.
library;

export 'src/apps/app_builder/app_builder.dart';
// `builtin_app.dart` (the BuiltInApp / BuiltInAppRegistry contract) moved
// to `src/base/install/builtin_app.dart` and is now re-exported through
// `base.dart` — it is host-shared infrastructure, not app_builder-owned.
export 'src/apps/app_builder/builtin_app_registry_bootstrap.dart';
export 'src/apps/scene_builder/scene_builder.dart';
export 'src/apps/ops/ops_builtin.dart' show OpsBuiltInApp;
