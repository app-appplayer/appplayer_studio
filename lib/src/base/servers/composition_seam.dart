/// Composition Profile wiring for served surfaces (MCP UI DSL v1.4).
///
/// A served screen may `$ref` a definition that lives on ANOTHER MCP server and
/// then drive and track that server's device. The runtime asks the host for
/// four capabilities to do it; the `composition_host` recipe builds all four
/// over the kernel's outbound `mcp.*` surface, so composition needs no new
/// transport, no second connection registry and no manifest field.
///
/// This file holds the studio-side half: a boot-registered seam carrying the
/// two things the recipe cannot discover on its own — how to call a kernel tool
/// in-process, and how to open an origin the host is not currently connected
/// to. Both are host knowledge, so both are injected once at boot rather than
/// threaded through every widget that might render a served app.
///
/// Registering ALL FOUR hooks is the point. A host that wires only the resolver
/// ships a screen that renders and does nothing: controls inside the embedded
/// subtree take the app's own path and land on a session with no client for
/// that device. [CompositionHooks] is one object for exactly that reason, and
/// [applyCompositionHooks] registers the whole set or none of it.
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:meta/meta.dart';

import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    show MCPUIRuntime;

import '../../../runtime.dart' as studio show MCPUIRuntime;
import '../install/composition_host/composition_host.dart';

/// A host tool dispatcher — `BuiltinToolRegistry.callTool` in the live host.
typedef HostToolCall =
    Future<mk.KernelToolResult> Function(
      String tool,
      Map<String, dynamic> args,
    );

/// Adapts a host tool dispatcher to the recipe's [KernelToolCall].
///
/// The kernel wraps every result as JSON text, so the payload is decoded back
/// to an object here; the recipe's own unwrapping then takes it from
/// `{contents: [...]}` down to the body. Text that is not JSON is returned as
/// text rather than discarded — a device serving a plain string is answering,
/// not failing.
KernelToolCall kernelToolCallFrom(HostToolCall callTool) {
  return (tool, args) async {
    final result = await callTool(tool, args);
    final text =
        result.content
            .whereType<mk.KernelTextContent>()
            .map((c) => c.text)
            .join();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  };
}

/// The boot-registered composition seam.
///
/// Static because the host learns these once at boot while the surfaces that
/// need them are built much later, in two tiers, from three call sites. The
/// same late-injection shape the ops runner seams use.
class StudioCompositionSeam {
  StudioCompositionSeam._();

  static KernelToolCall? _call;
  static OpenOrigin? _openOrigin;
  static mk.KernelClientHost? Function()? _clientHost;

  /// Wire the seam. [call] drives the kernel's in-process `mcp.*` tools;
  /// [clientHost] is THE host's one outbound connection registry; [openOrigin]
  /// opens an origin the host does not currently hold.
  ///
  /// One registry, deliberately: a device gets ONE connection, shared by the
  /// composed screen and by opening that device on its own. Two registries
  /// keyed by the same device id each miss the other's connection and re-dial,
  /// which on a single-peer board is a refusal that reads as a broken device.
  ///
  /// [openOrigin] is optional and deliberately so: a host that cannot re-open a
  /// dropped origin still composes over the ones it holds, and a missing opener
  /// degrades to "origin is not connected" rather than to silence.
  static void register({
    required KernelToolCall call,
    required mk.KernelClientHost? Function() clientHost,
    OpenOrigin? openOrigin,
  }) {
    _call = call;
    _clientHost = clientHost;
    _openOrigin = openOrigin;
  }

  /// True once [register] has run — composition is claimable.
  static bool get isWired => _call != null;

  /// Build the four hooks for a surface, or null when the seam is unwired
  /// (headless mounts, tests). A null result must leave the runtime WITHOUT a
  /// resolver so `view` fails closed to its fallback, rather than resolving a
  /// foreign `$ref` against this surface's own server.
  /// [clientHost] overrides the registered registry — surfaces that already
  /// hold the handle pass it; it is the same instance either way.
  static CompositionHooks? hooksFor({
    mk.KernelClientHost? Function()? clientHost,
    ReadOwnDefinition? readOwn,
  }) {
    final call = _call;
    if (call == null) return null;
    return buildCompositionHooks(
      call: call,
      clientHost: clientHost ?? _clientHost ?? () => null,
      openOrigin: _openOrigin,
      readOwn: readOwn,
    );
  }

  @visibleForTesting
  static void resetForTest() {
    _call = null;
    _clientHost = null;
    _openOrigin = null;
  }
}

/// The "all four, or nothing" rule — stated once.
///
/// The studio renders composed screens on TWO runtimes that are separate Dart
/// types on purpose: served services drive `package:flutter_mcp_ui_runtime`,
/// while the authoring / bundle surface drives the vendored fork
/// (`package:appplayer_studio/runtime.dart`) so their singletons cannot
/// collide. Both must claim the profile identically, so the rule lives here and
/// each surface passes its own four registrars.
void _applyAll(
  CompositionHooks? hooks, {
  required void Function(
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>),
  )
  resolver,
  required void Function(
    Future<dynamic> Function(
      Map<String, dynamic>,
      String,
      Map<String, dynamic>,
    ),
  )
  toolCaller,
  required void Function(
    Future<void Function()> Function(
      Map<String, dynamic>,
      String,
      void Function(dynamic),
    ),
  )
  watcher,
  required void Function(Future<Object?> Function(Map<String, dynamic>, String))
  reader,
}) {
  if (hooks == null) return;
  resolver(hooks.resolveDefinition);
  toolCaller(hooks.callTool);
  watcher(hooks.watchResource);
  reader(hooks.readResource);
}

/// Register [hooks] on a served-service runtime (the pub package type).
void applyCompositionHooks(MCPUIRuntime runtime, CompositionHooks? hooks) =>
    _applyAll(
      hooks,
      resolver: runtime.registerDefinitionResolver,
      toolCaller: runtime.registerOriginToolCaller,
      watcher: runtime.registerOriginResourceWatcher,
      reader: runtime.registerOriginResourceReader,
    );

/// Register [hooks] on the authoring / bundle runtime (the vendored fork type).
///
/// The reference multi-origin bundle (`apps/multi_device.mbd`) is a STUDIO
/// bundle, not a served app: its `view`s name connections and it renders on
/// this runtime. Wiring only the served surface would leave the very screen the
/// profile exists for rendering its fallbacks.
void applyCompositionHooksToStudioRuntime(
  studio.MCPUIRuntime runtime,
  CompositionHooks? hooks,
) => _applyAll(
  hooks,
  resolver: runtime.registerDefinitionResolver,
  toolCaller: runtime.registerOriginToolCaller,
  watcher: runtime.registerOriginResourceWatcher,
  reader: runtime.registerOriginResourceReader,
);
