/// `VbuBundleEmbed` — placeholder marker widget for embedding another
/// mbd's `ui/app.json` as a sub-runtime. The factory (registered in
/// `vibe_studio_base/.../vbu_widgets.dart`) reads `bundlePath` /
/// `uiPath` from the DSL definition and mounts a fresh `MCPUIRuntime`
/// instance to render the target bundle's UI. The atom itself stays in
/// `vibe_studio_ui` so the registration site can construct it without
/// adding a runtime dependency at the atom layer — actual rendering
/// happens via the factory, which lives in base where the runtime is
/// already imported.
///
/// This widget is the placeholder used when no factory wires up the
/// type. The host should always register a factory; this fallback
/// surfaces a clear error message in that case.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

class VbuBundleEmbed extends StatelessWidget {
  const VbuBundleEmbed({
    super.key,
    required this.bundlePath,
    this.uiPath = 'ui/app.json',
  });

  /// Absolute path to the bundle root (`.mbd/` directory).
  final String bundlePath;

  /// `manifest.ui.path` — relative path inside the bundle. Defaults to
  /// the canonical `ui/app.json`.
  final String uiPath;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(VbuTokens.space5),
        child: Text(
          'VbuBundleEmbed placeholder — no factory wired.\n'
          'bundlePath: $bundlePath\nuiPath: $uiPath',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.textTertiary,
          ),
        ),
      ),
    );
  }
}
