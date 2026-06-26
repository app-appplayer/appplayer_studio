/// VENDORED capability_tools recipe (publish_to:none reference) — the
/// integrated capability pack + the examples Studio adopts. Vendored, not
/// path-dep'd: the recipe's pubspec carries a `brain_kernel` path dep that
/// would clash with Studio's hosted brain_kernel. Re-sync from
/// `os/core/brain_kernel/recipes/capability_tools/lib/src/*` when the recipe
/// changes — DO NOT hand-edit. Package imports (mcp_canvas / mcp_analysis /
/// mcp_datastore / brain_kernel) resolve against Studio's own deps.
library;

export 'src/capability_tool_pack.dart';
export 'src/canvas_example.dart';
export 'src/analysis_example.dart';
export 'src/analysis_standard.dart';
export 'src/kv_example.dart';
export 'src/datastore_example.dart';
