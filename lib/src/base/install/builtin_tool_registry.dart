/// `BuiltinToolRegistry` — facade for builtins that need to register
/// MCP tools / resources / prompts on the host endpoint.
///
/// A read-friendly wrapper over the host-side `mk.KernelServerHost`. When
/// a builtin calls `boot.addTool(...)` inside `BuiltInApp.registerHostTools`
/// / `mount`, it uses only the wrapper API without exposing kernel-level
/// handles.
///
/// Model alignment — host = OS · builtin = app on top of the OS:
///   - only the host uses `mk.KernelServerHost` (= mcp_host's ServerBootstrap) directly.
///   - builtins use only this wrapper → zero direct dependency on kernel symbols.
///   - same surface as the bundle-app path — builtin code is portable to a bundle-app as-is.
///
/// Recommended path: tool registration via a **manifest `tools[]` declaration**
/// is the source of truth (the host activation path registers it
/// automatically). This wrapper is used only where a builtin must wire a
/// dart handler directly (e.g. UI debug tools · capture tools).
library;

import 'package:brain_kernel/brain_kernel.dart' as mk;

/// Tool handler signature — `(args) → KernelToolResult`. Builtin code
/// imports only `KernelToolResult` / `KernelTextContent` from
/// `builtin_api.dart`, so it has zero direct dependency on kernel symbols.
typedef BuiltinToolHandler =
    Future<mk.KernelToolResult> Function(Map<String, dynamic> args);

/// Resource handler signature — `(uri, params) → KernelReadResourceResult`.
typedef BuiltinResourceHandler =
    Future<mk.KernelReadResourceResult> Function(
      String uri,
      Map<String, dynamic>? params,
    );

/// Facade for the host MCP endpoint. Created by the host (passing in
/// the live `KernelServerHost`); handed to `BuiltInApp.registerHostTools`
/// + `BuiltInApp.mount` so builtins never see the raw kernel handle.
class BuiltinToolRegistry {
  BuiltinToolRegistry(this._boot);

  final mk.KernelServerHost _boot;

  /// Register an MCP tool. Same semantics as `KernelServerHost.addTool`
  /// minus the host-only `kernelChecker` / `validator` paths (those stay
  /// host-internal — builtins shouldn't override them).
  void addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required BuiltinToolHandler handler,
  }) {
    // Multi-mount safety: a built-in tab can re-mount (re-opened from
    // Home, IndexedStack rebuild, hot restart), and each mount registers
    // its tool surface on the shared host endpoint via a fresh
    // ServerBootstrap. Drop any prior registration of the same name so
    // re-registration replaces it instead of the host throwing
    // "Tool with name ... already exists". Built-ins are single-instance
    // (one domain, one project) so the latest mount IS the live one —
    // replace-on-remount keeps the host tool pointed at it.
    _boot.removeTool(name);
    _boot.addTool(
      name: name,
      description: description,
      inputSchema: inputSchema,
      handler: handler,
    );
  }

  /// Remove a previously-registered tool. Used by builtins that swap
  /// their tool surface mid-lifecycle (rare — most use addTool once).
  /// Returns true when a tool with [name] was actually removed.
  bool removeTool(String name) {
    return _boot.removeTool(name);
  }

  /// Register an MCP resource (e.g. `makemind-ops://guide` for the
  /// docs surface). Builtins typically expose docs / live-state /
  /// catalogue through resources; tools fire actions.
  void addResource({
    required String uri,
    required String name,
    required String description,
    required String mimeType,
    required BuiltinResourceHandler handler,
  }) {
    // Multi-mount safety (see addTool): drop any prior registration so a
    // re-mounted built-in re-registering the same resource URI replaces
    // it instead of the host throwing "Resource with URI ... already
    // exists".
    _boot.removeResource(uri);
    _boot.addResource(
      uri: uri,
      name: name,
      description: description,
      mimeType: mimeType,
      handler: handler,
    );
  }

  /// Remove a previously-registered resource. Returns true when an
  /// entry was actually removed.
  bool removeResource(String uri) {
    return _boot.removeResource(uri);
  }

  /// Register an MCP prompt (cherry r8 — 2026-05-28).
  ///
  /// Builtins call this for first-entry / onboarding text presets
  /// (`getting_started` · `drive_workspace` · etc.) the external MCP
  /// client surfaces in its "Prompts" picker. `arguments` declare the
  /// fillable slots; `handler` returns the composed `KernelGetPromptResult`
  /// (messages + optional description).
  void addPrompt({
    required String name,
    required String description,
    required List<mk.KernelPromptArgument> arguments,
    required mk.KernelPromptHandler handler,
  }) {
    // Multi-mount safety (see addTool): replace prior registration so a
    // re-mounted built-in re-registering the same prompt name does not
    // throw "already exists".
    _boot.removePrompt(name);
    _boot.addPrompt(
      name: name,
      description: description,
      arguments: arguments,
      handler: handler,
    );
  }

  /// Remove a previously-registered prompt. Returns true when an entry
  /// was actually removed.
  bool removePrompt(String name) {
    return _boot.removePrompt(name);
  }

  /// Call a tool already registered on the host endpoint. Used when a
  /// builtin's handler needs to chain into another tool's behavior
  /// (e.g. `app_builder.newAppProject` ➝ `studio.project.new`) without
  /// reaching for the raw `KernelServerHost`. Returns the same
  /// `KernelToolResult` the original handler produced.
  Future<mk.KernelToolResult> callTool(String name, Map<String, dynamic> args) {
    return _boot.callTool(name, args);
  }
}
