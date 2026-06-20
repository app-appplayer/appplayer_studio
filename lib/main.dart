/// vibe_studio universal host entry. Domain code is zero — the host
/// composes the base/ chrome with the workspace/ DSL renderer
/// (lib/src/<area>/ inside this single package). Bundles ship their
/// own MCP endpoints + DSL UI.
library;

import 'package:appplayer_studio/apps.dart' as apps;
import 'package:appplayer_studio/base.dart';

import 'src/main/vibe_studio_host_app.dart';

Future<void> main(List<String> args) async {
  // Register every built-in app exposed by the apps/ area so the
  // host's bundleBodyBuilder can discover them through the registry
  // (no per-app if-branch in host code).
  apps.registerBuiltInApps();
  await StudioMain.run(
    rawArgs: args,
    factory: (parsed) async => VibeStudioHostApp(),
  );
}
