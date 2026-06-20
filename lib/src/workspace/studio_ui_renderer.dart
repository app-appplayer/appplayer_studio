/// Top-level workspace renderer — picks the right rendering path
/// based on the bundle's `manifest.ui.kind`. The activation contract
/// hands a `BundleManifest` (with optional `UiEntryPoint`) to the
/// host, which mounts this widget when the active tab's bundle
/// declares UI.
///
/// **Phase 3.1 of `vibe-studio-activation-plan`** — supports
/// `mcp_ui_dsl` (delegates to the existing [DslWorkspaceView]
/// instance, which embeds `flutter_mcp_ui_runtime`). The
/// `studio_ui` path returns a placeholder pending Phase 3.2 (vbu
/// atom registration into the renderer's custom-widget catalog).
///
/// Consumers (the universal host) wrap the bundle's `mbdPath` and
/// the parsed `UiEntryPoint`; this widget owns the dispatch.
library;

import 'package:flutter/material.dart';
import 'package:appplayer_studio/base.dart' show ChromeBridge;
import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'dsl_workspace_view.dart';

/// Discriminator literals for [UiEntryKind] — kept as a string at
/// the workspace boundary so the manifest's raw value can flow
/// through without a base ↔ workspace dependency cycle. Hosts that
/// have already parsed a `BundleManifest` should pass the manifest's
/// `ui.kind` field verbatim.
class UiEntryKinds {
  static const String mcpUiDsl = 'mcp_ui_dsl';
  static const String studioUi = 'studio_ui';
}

class StudioUiRenderer extends StatelessWidget {
  const StudioUiRenderer({
    super.key,
    required this.bundlePath,
    required this.uiKind,
    required this.uiPath,
    this.boot,
    this.chromeBridge,
    this.initialState,
    this.placeholder,
    this.errorBuilder,
  });

  /// Absolute path to the bundle root (`.mbd/` directory).
  final String bundlePath;

  /// `manifest.ui.kind` — see [UiEntryKinds].
  final String uiKind;

  /// `manifest.ui.path` — relative path inside the bundle (e.g.
  /// `'ui/app.json'`). Only meaningful for `mcp_ui_dsl` for now.
  final String uiPath;

  /// Optional MCP `ServerBootstrap` for routing `type: "tool"`
  /// actions inside the bundle UI through the host's MCP server.
  /// When null, tool actions silently no-op (useful in previews).
  final mk.KernelServerHost? boot;

  /// Optional chrome bridge — when supplied, the DSL workspace wires
  /// `bridge.updateRuntimeState` to its runtime so host paths (chrome
  /// row 2 icon clicks, external MCP `studio.renderer.activate`
  /// callers) can push state into the running DSL.
  final ChromeBridge? chromeBridge;

  /// Initial DSL state — written to the runtime right after
  /// `initialize` so bindings have host-known values (e.g.,
  /// `currentProject` for embedded target previews) before the user
  /// interacts.
  final Map<String, dynamic>? initialState;

  final Widget? placeholder;
  final Widget Function(BuildContext, Object error)? errorBuilder;

  @override
  Widget build(BuildContext context) {
    switch (uiKind) {
      case UiEntryKinds.mcpUiDsl:
        return DslWorkspaceView(
          bundlePath: bundlePath,
          boot: boot,
          chromeBridge: chromeBridge,
          initialState: initialState,
          placeholder: placeholder,
          errorBuilder: errorBuilder,
        );
      case UiEntryKinds.studioUi:
        return _StudioUiPlaceholder(uiPath: uiPath);
      default:
        return _UnknownKindPane(uiKind: uiKind);
    }
  }
}

class _StudioUiPlaceholder extends StatelessWidget {
  const _StudioUiPlaceholder({required this.uiPath});
  final String uiPath;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'studio_ui renderer not yet wired (Phase 3.2).\n'
          'Bundle UI entry: $uiPath',
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }
}

class _UnknownKindPane extends StatelessWidget {
  const _UnknownKindPane({required this.uiKind});
  final String uiKind;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Unknown ui.kind: "$uiKind".\n'
          'Expected one of: ${UiEntryKinds.mcpUiDsl}, ${UiEntryKinds.studioUi}.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }
}
