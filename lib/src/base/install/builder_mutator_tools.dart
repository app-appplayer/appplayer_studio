/// `registerBuilderMutatorTools` — register the `studio.builder.*`
/// manifest-mutator MCP tools onto a kernel host.
///
/// The body of the tools (manifest read / write, idempotent keys,
/// validation, a snapshot before each change) is the shared recipe
/// `builder_mutator`, vendored as `builder_mutator_core.dart`
/// (`debug/tool/sync_builder_mutator_fork.sh`); it touches no screen.
/// This file is the Studio adapter: it wraps [ChromeBridge] as the
/// recipe's [BuilderViewHooks], so after a change the tab is marked
/// modified, the view the change points at is opened and the tab is
/// reloaded — the same code path as a user click. The bridge setters are
/// read each time, so the shell may wire them after registration.
///
/// Every studio host calls this once during `registerMcpTools` so the
/// builder surface stays identical across studios.
library;

import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../main/chrome_bridge.dart';
import 'builder_mutator_core.dart' as core;

/// Register the `studio.builder.*` mutator tools onto [boot]. Handlers
/// route through [bridge] for post-mutation view activation and tab
/// reload; the host wires the bridge setters when its shell mounts.
void registerBuilderMutatorTools(
  mk.KernelServerHost boot, {
  required ChromeBridge bridge,
}) {
  // The atomic `studio.builder.ui.*` tools are registered by the host
  // with the widget catalogue and the active project.
  core.registerBuilderMutatorTools(
    boot,
    hooks: _ChromeBridgeHooks(bridge),
    includeUiTools: false,
  );
}

class _ChromeBridgeHooks implements core.BuilderViewHooks {
  _ChromeBridgeHooks(this._bridge);

  final ChromeBridge _bridge;

  @override
  void Function()? get markActiveTabModified => _bridge.markActiveTabModified;

  @override
  void Function(int? index)? get reloadTab => _bridge.reloadTab;

  @override
  Map<String, dynamic> Function(String target, [Map<String, dynamic>? args])?
  get activateView => _bridge.activateView;
}
