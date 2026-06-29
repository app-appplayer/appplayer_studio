/// VENDORED `plugin_host` recipe (publish_to:none reference) — registers
/// plugins (bundle / server / hub) as first-class `<pluginId>.<tool>` providers
/// in the shared catalog so any app/agent consumes them.
///
/// Vendored, not path-dep'd: the recipe's pubspec carries a `brain_kernel` path
/// dep that would clash with Studio's hosted brain_kernel (same reason as
/// `capability_recipes`). DO NOT hand-edit — re-sync from
/// `os/core/brain_kernel/recipes/plugin_host/lib/src/*` when the recipe
/// changes. No import rewrite needed: the copied files import
/// `package:brain_kernel` (a real Studio dep) + a sibling relative import.
///
/// This is a behavioural reference, not frozen canon — if wiring surfaces a
/// better source/storage/lifecycle shape, feed it back to cherry.
library;

export 'src/plugin_source.dart';
export 'src/plugin_host.dart';
