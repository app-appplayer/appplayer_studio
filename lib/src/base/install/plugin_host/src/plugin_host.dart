/// Registers plugins into the shared tool catalog so any app/agent consumes
/// their tools as first-class `<pluginId>.<tool>` entries.
///
/// This is pure composition of kernel primitives — no new kernel concept:
/// - **server / hub**: `KernelClientHost.connect` → `listTools` → mirror each
///   tool with `HostToolRegistry.registerExposed` (handler routes to the
///   connection's `callTool`). Turns "the app drives `mcp.*` by hand" into
///   "register once, the tools are in the catalog".
/// - **bundle**: the host activates the bundle in plugin mode (kernel
///   `BundleActivation`, no UI mount) — activation already registers its tools
///   under the bundle id. [registerBundle] just records it for lifecycle.
library;

import 'package:brain_kernel/brain_kernel.dart';

import 'plugin_source.dart';

/// A registered plugin and the catalog entries it owns.
class RegisteredPlugin {
  RegisteredPlugin({
    required this.source,
    required this.rawNames,
    required this.exposedNames,
    this.connection,
  });

  final PluginSource source;

  /// Unprefixed tool names (used to unregister).
  final List<String> rawNames;

  /// Catalog names (`<pluginId>.<tool>`) other apps/agents call.
  final List<String> exposedNames;

  /// The live connection for `server`/`hub` kinds (null for `bundle`).
  final KernelClientConnection? connection;
}

class PluginHost {
  PluginHost(this._registry, {KernelClientHost? clientHost})
      : _clientHost = clientHost;

  final HostToolRegistry _registry;
  final KernelClientHost? _clientHost;
  final Map<String, RegisteredPlugin> _plugins = <String, RegisteredPlugin>{};

  Iterable<RegisteredPlugin> get plugins => _plugins.values;
  RegisteredPlugin? plugin(String id) => _plugins[id];

  /// Connect a `server`/`hub` plugin and mirror its `tools/list` into the
  /// catalog under `<source.id>.<tool>`. Each handler routes to the
  /// connection so a call reaches the real server.
  /// [toolRawNames] (optional) restricts the mirror to those tool names — a
  /// whitelist for large servers so only the needed tools become plugin tools.
  /// Null mirrors every tool the server lists.
  Future<RegisteredPlugin> registerServer(
    PluginSource source, {
    Iterable<String>? toolRawNames,
  }) async {
    final host = _clientHost;
    if (host == null) {
      throw StateError(
        'registerServer requires a KernelClientHost — the host must boot with '
        'one (clientHost). bundle plugins do not need it.',
      );
    }
    final conn = await host.connect(
      id: source.id,
      transport: source.transport ?? KernelTransportKind.streamableHttp,
      endpoint: source.endpoint,
      options: source.options,
    );
    final wanted = toolRawNames?.toSet();
    final tools = await conn.listTools();
    final rawNames = <String>[];
    final exposedNames = <String>[];
    for (final t in tools) {
      if (wanted != null && !wanted.contains(t.name)) continue;
      final exposed = _registry.registerExposed(
        bundleId: source.id,
        rawName: t.name,
        description: t.description,
        inputSchema: t.inputSchema,
        handler: (args) => conn.callTool(t.name, args),
      );
      rawNames.add(t.name);
      exposedNames.add(exposed);
    }
    final reg = RegisteredPlugin(
      source: source,
      rawNames: rawNames,
      exposedNames: exposedNames,
      connection: conn,
    );
    _plugins[source.id] = reg;
    return reg;
  }

  /// Record a `bundle` plugin whose tools the host already wired via the
  /// kernel `BundleActivation` (plugin mode = activate without mounting UI).
  /// [toolRawNames] are the activated bundle's tool names (without the id
  /// prefix) so [unregister] can tear them down symmetrically.
  RegisteredPlugin registerBundle(
    PluginSource source, {
    required List<String> toolRawNames,
  }) {
    final reg = RegisteredPlugin(
      source: source,
      rawNames: toolRawNames,
      exposedNames: [for (final n in toolRawNames) '${source.id}.$n'],
    );
    _plugins[source.id] = reg;
    return reg;
  }

  /// Remove a plugin's catalog entries and close any connection.
  Future<void> unregister(String id) async {
    final reg = _plugins.remove(id);
    if (reg == null) return;
    for (final raw in reg.rawNames) {
      _registry.unregisterExposed(bundleId: id, rawName: raw);
    }
    await reg.connection?.close();
  }
}
