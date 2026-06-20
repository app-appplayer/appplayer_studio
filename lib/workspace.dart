/// Public barrel for the workspace/ area (lib/src/workspace/). Pulled
/// in only by the universal `vibe_studio` host main entry — standalone
/// builders (vibe_app_builder, vkb) stay free of this barrel. The host
/// plugs `DslWorkspaceView` into its `buildShell` flow once the user
/// activates an installed bundle.
library;

export 'src/workspace/dsl_workspace_view.dart';
export 'src/workspace/studio_ui_renderer.dart';
