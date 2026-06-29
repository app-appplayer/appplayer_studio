/// VENDORED capability recipes (publish_to:none references) — the integrated
/// capability pack + the examples Studio adopts. Vendored, not path-dep'd: the
/// recipes' pubspecs carry a `brain_kernel` path dep that would clash with
/// Studio's hosted brain_kernel. DO NOT hand-edit — re-sync from the recipe
/// sources when they change:
///   - capability pack + pure-Dart examples ←
///     `os/core/brain_kernel/recipes/capability_tools/lib/src/*`
///   - secure / secret / migration (Flutter-bound, appplayer_secure) ←
///     `os/core/brain_kernel/recipes/secure_capability/lib/src/*`
///     (their `package:capability_tools` import is rewritten to the local
///     `capability_tool_pack.dart` on copy).
/// Package imports (mcp_canvas / mcp_analysis / mcp_datastore / brain_kernel /
/// appplayer_secure) resolve against Studio's own deps.
library;

export 'src/capability_tool_pack.dart';
export 'src/canvas_example.dart';
export 'src/analysis_example.dart';
export 'src/analysis_standard.dart';
export 'src/kv_example.dart';
export 'src/datastore_example.dart';
// secure_capability recipe (Flutter-bound).
export 'src/secure_example.dart';
export 'src/secret_example.dart';
export 'src/credential_migration.dart';
