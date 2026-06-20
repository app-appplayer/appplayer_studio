/// Shell representation a [StudioApp] hands back to [StudioMain]. Sealed
/// so the host knows exactly which path to take when mounting the GUI:
///
///   * [WidgetShellBlueprint] — domain owns a hand-written Flutter
///     widget. The path used today by `vibe_app_builder` /
///     `vibe_knowledge_builder` and (in Round A) by `vibe_studio` itself.
///   * [DslShellBlueprint] — domain ships an `.mcpb` bundle whose
///     `ui/app.json` is rendered by the kernel's `vibe_studio_runtime`
///     fork (Round B). Round A keeps this variant as a stub so the
///     contract is forward-compatible without forcing every host to
///     wire a runtime now.
///
/// The same `StudioApp` can return either shape — kernel + base treat
/// both identically when binding the chrome (Titlebar · ProjectHeader ·
/// Settings dialog · ChatPanel · Statusbar). Domain code only differs in
/// what fills the centre pane.
library;

import 'package:flutter/widgets.dart';

/// Sealed root of the two shell shapes a domain can return from
/// [StudioApp.buildShell]. Pattern-match on this in [StudioMain] (and
/// any future embedded host like a universal vibe_studio workspace) to
/// pick the rendering path.
sealed class ShellBlueprint {
  const ShellBlueprint();
}

/// Domain returns a Flutter [WidgetBuilder]. The host frames the result
/// in a `MaterialApp` + `Scaffold` and exposes the standard chrome
/// (`Titlebar`, `ProjectHeader`, `Statusbar`) — the builder is the
/// centre body the domain owns.
class WidgetShellBlueprint extends ShellBlueprint {
  const WidgetShellBlueprint(this.builder);

  final WidgetBuilder builder;
}

/// Domain returns a path to a `.mcpb` bundle whose `ui/app.json` is
/// rendered by `vibe_studio_runtime` (the namespaced mcp_ui_runtime
/// fork). [bundlePath] is resolved relative to the host launch
/// directory; [entryRoute] picks the initial route inside the bundle
/// (defaults to `'/'`).
///
/// Round A leaves runtime mounting as a no-op stub — hosts surface a
/// "DSL shell pending vibe_studio_runtime" placeholder. Round B wires
/// the actual runtime + `MCPUIRuntime.registerWidget` catalogue.
class DslShellBlueprint extends ShellBlueprint {
  const DslShellBlueprint({required this.bundlePath, this.entryRoute = '/'});

  final String bundlePath;
  final String entryRoute;
}
