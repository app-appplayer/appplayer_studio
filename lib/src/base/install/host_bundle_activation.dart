/// Default host-side implementation of [BundleActivationContext].
/// Wires bundle declarations into the host's MCP server with the
/// `<exposedShortId>.<verb>` prefix the activation plan uses.
///
/// `kind: 'mcp'` tools call their server through the kernel's outbound
/// client host (one connection per server per bundle, opened on first call,
/// closed with the bundle); `host.kb` goes to the kernel `kb` store keyed by
/// app identity ([StudioKbWiring]).
/// **Phase 4.1** — registers agents into [AgentHost.shared].
/// **Phase 5.4** — `kind: 'js'` tools load their `.js` source into a
/// per-bundle [JsToolRuntime] + [JsHostBridge] and dispatch via the
/// JS function declared by `target.fn`. The bridge exposes only atoms
/// listed in `bundle.requires.builtinAtoms`.
/// `mountUi` (Phase 3) still returns not-implemented.
///
/// **Step 3 absorption** — fork classes removed. Operates directly on
/// `mb.McpBundle` / `mb.ToolEntry` / `mb.AgentDefinition`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../session/session.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../agent/agent_host.dart';
import '../agent/agent_profile.dart';
import '../boot/studio_backbone.dart';
import '../canonical/workspace_canonical.dart';
import '../main/chrome_bridge.dart';
import 'atoms/agent_atom.dart';
import 'atoms/atom_category.dart';
import 'atoms/bundle_atom.dart';
import 'atoms/bus_atom.dart';
import 'atoms/fs_atom.dart';
import 'atoms/kb_atom.dart';
import 'atoms/mcp_atom.dart';
import 'atoms/ui_atom.dart';
import 'atoms/workspace_atom.dart';
import 'bundle_activation.dart';
import 'bundle_loading.dart';
import 'js_tool_runtime.dart';
import 'studio_kb.dart';

class HostBundleActivationContext implements BundleActivationContext {
  HostBundleActivationContext({
    required mk.KernelServerHost boot,
    required this.tabKey,
    required this.bundle,
    required this.exposedShortId,
    StudioKbWiring? kb,
    mk.KernelClientHost? Function()? clientHost,
    ChromeBridge? chromeBridge,
    WorkspaceCanonical? Function()? activeWorkspace,
    StudioBackbone? backbone,
    BundleSessionBridge? sessionBridge,
    http.Client? httpClient,
  }) : _boot = boot,
       _kb = kb,
       _clientHost = clientHost,
       _chromeBridge = chromeBridge,
       _activeWorkspace = activeWorkspace,
       _backbone = backbone,
       _sessionBridge = sessionBridge,
       _httpClient = httpClient;

  final mk.KernelServerHost _boot;

  /// HTTP client for `kind: 'cloud'` calls. Null → a client per call,
  /// closed after it. Tests inject one to answer without a network.
  final http.Client? _httpClient;

  /// The host's `host.kb` wiring (kernel key/value records, app identity,
  /// the one-time import of the former domain storage). Null → the bundle
  /// gets no `kb` atom.
  final StudioKbWiring? _kb;

  /// This activation's `kb` view, created on first use and kept: the store
  /// remembers the version it last saw per key, which is what makes a write
  /// safe against another writer.
  mk.BundleKbStore? _kbStore;

  mk.BundleKbStore? _kbStoreFor(mb.McpBundle b) {
    final kb = _kb;
    if (kb == null) return null;
    return _kbStore ??= kb.storeFor(b);
  }

  /// The kernel's outbound MCP client host — `kind: 'mcp'` tools open their
  /// connection there (bundle spec 04_Tools §4.5). Read per call so a host
  /// that boots its kernel later still serves the tool. Null → such a tool
  /// answers that this host has no outbound MCP client.
  final mk.KernelClientHost? Function()? _clientHost;

  /// Optional chrome bridge for the `host.ui` atom. When null the
  /// bundle's `ui.notify` / `ui.dialog` / `ui.prompt` calls fall back
  /// to the bridge's "no slot" reply (silent, not crashing).
  final ChromeBridge? _chromeBridge;

  /// Optional workspace provider for the `host.workspace` atom. Called
  /// fresh on every dispatch so projects can swap underneath the
  /// activation. When null, bundles requesting `'workspace'` see no
  /// surface at all (the atom isn't included in `_builtinAtomsFor`).
  final WorkspaceCanonical? Function()? _activeWorkspace;

  /// Optional backbone handle. When non-null, the 4-axis + fact + flow
  /// register* methods delegate to `_backbone!.app.system.<facade>`.
  /// Production callers (vibe_studio_host_app) pass this through;
  /// tests typically leave it null (those activation paths return
  /// `ok:false` with a clear "backbone not wired" error).
  final StudioBackbone? _backbone;

  /// Optional bundle-host bridge. When present, the activation also
  /// opens a `DispatchSession` so background dispatchers (JS bridge
  /// / agent / workflow / UI mount) running inside this bundle's
  /// `runScoped` see the right `scopeId` caller.
  final BundleSessionBridge? _sessionBridge;

  /// Session opened against [_sessionBridge] at first register* call,
  /// closed in [unregisterAll]. Null when no bridge is wired (e.g.
  /// in unit-test paths that exercise the activation without the
  /// host's session layer).
  DispatchSession? _session;
  DispatchSession? get session => _session;

  /// Lazy `BundleActivation` instance per this context. Created on
  /// first register* call (once backbone + boot are both wired). Same
  /// instance is registered into `BundleActivationRegistry.instance`
  /// so other surfaces (chat dispatch / ops scheduler) can lookup
  /// this bundle's catalog without re-wiring.
  mk.BundleActivation? _kernelActivation;

  mk.BundleActivation? get _ensureKernelActivation {
    if (_kernelActivation != null) return _kernelActivation;
    final backbone = _backbone;
    if (backbone == null || !backbone.isFlowBrainBooted) return null;
    _kernelActivation = mk.BundleActivation(
      system: backbone.app.system,
      bundleId: exposedShortId,
      boot: _boot,
    );
    mk.BundleActivationRegistry.instance.register(_kernelActivation!);
    // Tell the chrome bridge "tab `<tabKey>` is now bundle
    // `<exposedShortId>`" so `_setActiveContext` can scope
    // `DispatchContext` on tab switches. Chrome-layer state — kernel
    // is unaware of tabs.
    _chromeBridge?.mapTabBundle(tabKey, exposedShortId);
    // Open the bundle's session through the host bridge (if any).
    // This is what JS bridge / agent / workflow runner / UI mount
    // hand back to `bridge.runScoped(...)` so their tool calls see
    // the right scopeId caller regardless of which tab is foreground.
    _session ??= _sessionBridge?.openSession(_kernelActivation!);
    return _kernelActivation;
  }

  @override
  final String tabKey;

  @override
  final mb.McpBundle bundle;

  /// The shortId actually used for the host-side prefix. Equals
  /// `bundle.shortId` for the first instance; later instances of the
  /// same shortId get the `_2` / `_3` suffix the host computed.
  /// Stored as a field so callers can echo it back without recomputing.
  final String exposedShortId;

  /// Names registered on the host's MCP server through this context.
  /// `unregisterAll` walks this list and calls `removeTool` on each.
  final List<String> _registeredToolNames = <String>[];

  /// Client-host connections `kind: 'mcp'` tools of this bundle opened —
  /// one per server. `unregisterAll` closes them with the bundle.
  final Set<String> _mcpConnectionIds = <String>{};

  /// Agent ids registered via [registerAgent]. Tear-down calls
  /// `AgentHost.shared.removeProfile` for each (catalog only —
  /// FlowBrain agent stays in place for re-use).
  final List<String> _registeredAgentIds = <String>[];

  /// 4-axis + fact + flow ids registered through this context (Phase
  /// R2 of knowledge-operations). Each list is walked by
  /// `unregisterAll` so the facade pool stays clean when the tab
  /// closes.
  final List<String> _registeredSkillIds = <String>[];
  final List<String> _registeredProfileIds = <String>[];
  final List<String> _registeredPhilosophyIds = <String>[];
  final List<String> _registeredFactIds = <String>[];
  final List<String> _registeredFlowIds = <String>[];

  /// Lazily created when the first `kind: 'js'` tool is registered.
  /// Per-bundle isolate — disposed in [unregisterAll] so a tab close
  /// reclaims the underlying QuickJS runtime. The companion
  /// [JsHostBridge] is attached during `_ensureJsRuntime` and shares
  /// the runtime's lifetime (dropped together).
  JsToolRuntime? _jsRuntime;

  /// Result of the most recent [validateBuiltinTools] call. Empty
  /// before the first call or when the bundle declared no
  /// `requires.builtinTools`. Callers query this to surface missing
  /// dependencies in the activation UI / diagnostics.
  List<String> _missingBuiltinTools = const <String>[];

  bool _closed = false;

  @override
  bool get isClosed => _closed;

  /// Built-in tool ids the bundle declared in `requires.builtinTools`
  /// that are NOT present on the host's MCP server. Populated by
  /// [validateBuiltinTools]; empty before that runs (or when the
  /// bundle declared no requirements).
  List<String> get missingBuiltinTools =>
      List<String>.unmodifiable(_missingBuiltinTools);

  /// Cross-check `bundle.requires.builtinTools` against the host's
  /// MCP server. Returns `true` when every required tool is present
  /// (or none required). Returns `false` when any are missing — the
  /// caller should refuse activation and surface
  /// [missingBuiltinTools] to the user (Phase 5.5).
  ///
  /// Idempotent: repeated calls re-check against current server state
  /// (rare — host tools rarely change after boot, but tests + future
  /// hot-reload paths benefit from the freshness).
  bool validateBuiltinTools() {
    final required = bundle.requires?.builtinTools ?? const <String>[];
    if (required.isEmpty) {
      _missingBuiltinTools = const <String>[];
      return true;
    }
    final available = _boot.toolScopes.keys.toSet();
    final missing = <String>[
      for (final t in required)
        if (!available.contains(t)) t,
    ];
    _missingBuiltinTools = List<String>.unmodifiable(missing);
    return missing.isEmpty;
  }

  @override
  Future<RegistrationResult> registerTool(mb.ToolEntry tool) async {
    if (_closed) {
      return const RegistrationResult(
        ok: false,
        exposedName: '',
        error: 'context closed',
      );
    }
    switch (tool.kind) {
      case mb.ToolKind.js:
        return _registerJsTool(tool);
      case mb.ToolKind.mcp:
        return _registerMcpTool(tool);
      case mb.ToolKind.cloud:
        return _registerCloudTool(tool);
      case mb.ToolKind.ts:
        // `type: server` bundle tool — compiled and executed by the
        // marketplace serving runtime, never by this host (no local TS
        // executor by design). Treat as a declaration: skip
        // registration cleanly (ok, nothing exposed) rather than failing
        // the activation.
        return const RegistrationResult(ok: true, exposedName: '');
      default:
        return RegistrationResult(
          ok: false,
          exposedName: '',
          error: 'unknown tool kind: ${tool.kind.name}',
        );
    }
  }

  /// Wire a `kind: 'js'` tool. Lazily instantiates the per-bundle
  /// [JsToolRuntime] + [JsHostBridge], loads the JS source, and
  /// registers a handler that calls `target.fn(args)` on each
  /// invocation. Returns the registration outcome.
  Future<RegistrationResult> _registerJsTool(mb.ToolEntry tool) async {
    final entryPath = bundle.resolveJsEntry(tool);
    if (entryPath == null) {
      return RegistrationResult(
        ok: false,
        exposedName: '',
        error: 'kind=js tool "${tool.name}" missing target.entry',
      );
    }
    final fnRaw = tool.target['fn'];
    if (fnRaw is! String || fnRaw.isEmpty) {
      return RegistrationResult(
        ok: false,
        exposedName: '',
        error: 'kind=js tool "${tool.name}" missing target.fn',
      );
    }
    final fn = fnRaw;

    final rt = await _ensureJsRuntime();

    // Read + evaluate the source so the function is defined in the
    // runtime's global scope. Subsequent calls invoke it by name.
    final entryRel = tool.target['entry']?.toString() ?? tool.name;
    final String source;
    try {
      source = await File(entryPath).readAsString();
    } catch (e) {
      return RegistrationResult(
        ok: false,
        exposedName: '',
        error: 'kind=js tool "${tool.name}" load failed: $e',
      );
    }
    final loadResult = await rt.evaluate(source, sourceUrl: entryRel);
    if (loadResult.isError) {
      return RegistrationResult(
        ok: false,
        exposedName: '',
        error:
            'kind=js tool "${tool.name}" parse error: '
            '${loadResult.stringResult}',
      );
    }

    final exposedName = '$exposedShortId.${tool.name}';
    final desc =
        tool.description ??
        'In-process JS tool ${tool.name} (entry: $entryRel · fn: $fn).';
    // Per-bundle JS tool — register through the session bridge when
    // wired (so the bridge map + vibe_studio's external MCP endpoint
    // stay in sync). Fall back to `_boot.addTool` for the unit-test
    // path that exercises activation without a bridge.
    final jsSchema =
        tool.inputSchema ??
        const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        };
    Future<mk.KernelToolResult> jsHandler(Map<String, dynamic> args) async {
      if (_closed) {
        return _errorResult('context closed (tab is being torn down)');
      }
      // `evaluateAsync` settles a plain return and a Promise the same way.
      // Args round-trip through JSON so JS gets a plain object.
      final argsJson = jsonEncode(args);
      final code = '$fn(JSON.parse(${jsonEncode(argsJson)}))';
      try {
        final result = await rt.evaluateAsync(code);
        if (result.isError) {
          return _errorResult(
            'JS dispatch error: ${result.stringResult}',
            extra: <String, dynamic>{'exposedName': exposedName, 'fn': fn},
          );
        }
        // The worker stringifies the settled value inside JS, so the text is
        // JSON on every engine (`undefined` arrives as `null`).
        final raw = result.stringResult;
        final body = raw.isEmpty ? 'null' : raw;
        return mk.KernelToolResult(
          content: <mk.KernelContent>[mk.KernelTextContent(text: body)],
          isError: false,
        );
      } catch (e) {
        return _errorResult(
          'JS dispatch threw: $e',
          extra: <String, dynamic>{'exposedName': exposedName, 'fn': fn},
        );
      }
    }

    // Domain tools register through the endpoint directly — bridge
    // path is reserved for knowledge tools (`bk.<facade>.<verb>`),
    // enforced by the `BundleSessionBridge` validator that throws on
    // non-`bk.` names.
    _boot.addTool(
      name: exposedName,
      description: desc,
      inputSchema: jsSchema,
      handler: jsHandler,
    );
    _registeredToolNames.add(exposedName);
    return RegistrationResult(ok: true, exposedName: exposedName);
  }

  /// Wire a `kind: 'mcp'` tool — call the remote tool (`target.tool`, or this
  /// entry's own name) on the server `target` names (bundle spec 04_Tools
  /// §4.5).
  ///
  /// The connection belongs to the kernel's outbound client host under
  /// `bundle:<bundle id>:<endpoint>` — one per server per bundle, reused by
  /// every tool naming that server, closed with the bundle. A private client
  /// per registration was a second connection registry beside the client
  /// host's. The studio is a desktop host, so `transport: stdio` starts the
  /// local process the target names. The connection is opened on the first
  /// call; each call reports its own failure so the tool stays listed and
  /// says what is wrong.
  Future<RegistrationResult> _registerMcpTool(mb.ToolEntry tool) async {
    final exposedName = '$exposedShortId.${tool.name}';
    final target = tool.target;
    final transport = target['transport']?.toString();
    final url = target['url']?.toString() ?? '';
    final command = target['command']?.toString() ?? '';
    final endpointLabel = transport == 'stdio' ? command : url;
    final remote =
        target['tool'] is String && (target['tool'] as String).isNotEmpty
            ? target['tool'] as String
            : tool.name;
    final connectionId = 'bundle:${bundle.manifest.id}:$endpointLabel';
    final desc =
        tool.description ??
        'Bundle tool ${tool.name} (proxied to ${transport ?? '?'}).';
    final mcpSchema =
        tool.inputSchema ??
        const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        };
    Future<mk.KernelToolResult> mcpHandler(Map<String, dynamic> args) async {
      if (_closed) {
        return _errorResult('context closed (tab is being torn down)');
      }
      final extra = <String, dynamic>{
        'tabKey': tabKey,
        'exposedName': exposedName,
        'originalName': tool.name,
        'transport': transport ?? '?',
        if (endpointLabel.isNotEmpty) 'endpoint': endpointLabel,
      };
      final host = _clientHost?.call();
      if (host == null) {
        return _errorResult(
          'mcp tool ${tool.name} cannot run: this host has no outbound MCP '
          'client',
          extra: extra,
        );
      }
      final mk.KernelTransportKind kind;
      String? endpoint;
      Map<String, dynamic>? options;
      switch (transport) {
        case 'http':
          if (url.isEmpty) {
            return _errorResult(
              'mcp tool ${tool.name} needs target.url for transport http',
              extra: extra,
            );
          }
          kind = mk.KernelTransportKind.streamableHttp;
          endpoint = url;
        case 'stdio':
          if (command.isEmpty) {
            return _errorResult(
              'mcp tool ${tool.name} needs target.command for transport stdio',
              extra: extra,
            );
          }
          kind = mk.KernelTransportKind.stdio;
          options = <String, dynamic>{
            'command': command,
            'args':
                (target['args'] as List?)?.whereType<String>().toList() ??
                const <String>[],
          };
        default:
          return _errorResult(
            'mcp tool ${tool.name}: unknown transport ${transport ?? '(none)'}',
            extra: extra,
          );
      }
      try {
        final connection = await host.connect(
          id: connectionId,
          transport: kind,
          endpoint: endpoint,
          options: options,
        );
        _mcpConnectionIds.add(connectionId);
        final result = await connection.callTool(remote, args);
        return mk.KernelToolResult(
          content: result.content,
          isError: result.isError ?? false,
        );
      } catch (e) {
        return _errorResult('external dispatch failed: $e', extra: extra);
      }
    }

    _boot.addTool(
      name: exposedName,
      description: desc,
      inputSchema: mcpSchema,
      handler: mcpHandler,
    );
    _registeredToolNames.add(exposedName);
    return RegistrationResult(ok: true, exposedName: exposedName);
  }

  /// Wire a `kind: 'cloud'` tool — POST the call's input as JSON to
  /// `target.url` and answer the JSON response. Only `https` is accepted.
  /// A non-2xx status or a body that is not JSON fails the call with the
  /// reason; it is never turned into an empty result. An empty body answers
  /// `{}`. The target is checked per call, like the mcp proxy, so the tool
  /// stays listed and each call says what is wrong with the manifest.
  Future<RegistrationResult> _registerCloudTool(mb.ToolEntry tool) async {
    final exposedName = '$exposedShortId.${tool.name}';
    final url = tool.target['url'];
    final desc =
        tool.description ?? 'Bundle tool ${tool.name} (HTTPS POST to $url).';
    final cloudSchema =
        tool.inputSchema ??
        const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        };
    Future<mk.KernelToolResult> cloudHandler(Map<String, dynamic> args) async {
      if (_closed) {
        return _errorResult('context closed (tab is being torn down)');
      }
      final extra = <String, dynamic>{
        'exposedName': exposedName,
        'url': '$url',
      };
      final uri = url is String ? Uri.tryParse(url) : null;
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        return _errorResult(
          'cloud tool ${tool.name} needs an https target.url, got: $url',
          extra: extra,
        );
      }
      final client = _httpClient ?? http.Client();
      try {
        final response = await client.post(
          uri,
          headers: const <String, String>{'content-type': 'application/json'},
          body: jsonEncode(args),
        );
        if (response.statusCode < 200 || response.statusCode > 299) {
          return _errorResult(
            'cloud tool ${tool.name} failed: '
                    '${response.statusCode} ${response.reasonPhrase ?? ''}'
                .trim(),
            extra: extra,
          );
        }
        final body = utf8.decode(response.bodyBytes);
        if (body.trim().isEmpty) {
          return mk.KernelToolResult(
            content: <mk.KernelContent>[mk.KernelTextContent(text: '{}')],
            isError: false,
          );
        }
        try {
          jsonDecode(body);
        } on FormatException {
          return _errorResult(
            'cloud tool ${tool.name} answered a body that is not JSON '
            '(${response.bodyBytes.length} bytes)',
            extra: extra,
          );
        }
        return mk.KernelToolResult(
          content: <mk.KernelContent>[mk.KernelTextContent(text: body)],
          isError: false,
        );
      } catch (e) {
        return _errorResult(
          'cloud tool ${tool.name} request failed: $e',
          extra: extra,
        );
      } finally {
        if (_httpClient == null) client.close();
      }
    }

    _boot.addTool(
      name: exposedName,
      description: desc,
      inputSchema: cloudSchema,
      handler: cloudHandler,
    );
    _registeredToolNames.add(exposedName);
    return RegistrationResult(ok: true, exposedName: exposedName);
  }

  @override
  Future<RegistrationResult> registerAgent(mb.AgentDefinition agent) async {
    if (_closed) {
      return const RegistrationResult(
        ok: false,
        exposedName: '',
        error: 'context closed',
      );
    }
    final host = AgentHost.shared;
    if (host == null) {
      return const RegistrationResult(
        ok: false,
        exposedName: '',
        error: 'AgentHost not initialised yet',
      );
    }
    // `<shortId>.<agent.id>` is the exposed id. `addProfile(replace:true)`
    // below handles re-bind idempotently — when the host's baseline
    // already registered the same id (built-in apps' seed manifests
    // fold into baseline at boot via `agentProfiles`), the activation
    // just refreshes the entry instead of forking a `_2` duplicate.
    final exposedId = '$exposedShortId.${agent.id}';
    // mb.AgentDefinition shape mapping:
    //   displayName <- agent.name (always present, may be empty)
    //   provider    <- agent.model?.provider (nullable; default anthropic)
    //   modelId     <- agent.model?.model
    //   toolNames   <- agent.tools (nullable; default empty)
    final displayName = agent.name.trim().isEmpty ? exposedId : agent.name;
    final provider = agent.model?.provider;
    final modelId = agent.model?.model;
    final toolNames = agent.tools ?? const <String>[];
    // Bundle agents that declare no model inherit the configured default
    // (settings.llmModel resolved → catalog provider, else first wired;
    // threaded via AgentHost.defaultAgentModel) instead of a hardcoded id.
    final inherited = host.defaultAgentModel;
    final profile = VibeAgentProfile(
      id: exposedId,
      displayName: displayName,
      provider:
          (provider == null || provider.isEmpty)
              ? (inherited?.provider ?? 'anthropic')
              : provider,
      modelId: modelId ?? inherited?.model ?? 'claude-haiku-4-5-20251001',
      role: _agentRoleFromString(agent.role),
      systemPrompt:
          agent.systemPrompt ??
          'You are the ${agent.role} agent for $exposedShortId.',
      toolNames: toolNames,
    );
    try {
      // replace:true so stale instance from a prior activation gets
      // unregistered + re-created with the current manifest's metadata.
      // Without this, agent.list reports both old and new entries
      // (`<id>` + `<id>_2`).
      await host.addProfile(profile, replace: true);
    } catch (e) {
      return RegistrationResult(
        ok: false,
        exposedName: '',
        error: 'addProfile failed: $e',
      );
    }
    _registeredAgentIds.add(exposedId);
    _publishKbResource('agent', exposedId);
    return RegistrationResult(ok: true, exposedName: exposedId);
  }

  // ── 4-axis + flow + fact registration ──────────────────────────
  //
  // Each register* method below mirrors `registerAgent`'s shape: id is
  // prefixed with `<exposedShortId>.<entry.id>` so multi-tab bundles
  // don't collide on global facade registries. The actual delegation
  // to `system.skill.register / profile.register / philosophy.register
  // / facts.writeFacts / ops.registerWorkflow` lands once the host
  // wires its `StudioBackbone` reference into this context (parallel
  // path to `AgentHost.shared`). Until then the stub returns
  // `ok:false` with a clear error so callers can detect the gap
  // without crashing.

  /// Standard wrapper that delegates to the kernel `BundleActivation`.
  /// All five categories (skill/profile/philosophy/fact/flow) share
  /// this pattern — kernel owns the asset registration logic
  /// (namespace prefix + facade calls); the host side only converts
  /// to `RegistrationResult` and checks `closed`.
  Future<RegistrationResult> _delegate(
    String exposedIdPrediction,
    Future<String> Function(mk.BundleActivation a) op,
  ) async {
    if (_closed) {
      return const RegistrationResult(
        ok: false,
        exposedName: '',
        error: 'context closed',
      );
    }
    final activation = _ensureKernelActivation;
    if (activation == null) {
      return RegistrationResult(
        ok: false,
        exposedName: exposedIdPrediction,
        error: 'backbone not wired',
      );
    }
    try {
      final id = await op(activation);
      return RegistrationResult(ok: true, exposedName: id);
    } catch (e) {
      return RegistrationResult(
        ok: false,
        exposedName: exposedIdPrediction,
        error: '$e',
      );
    }
  }

  /// Publish a `kb://<facade>/<exposedId>` resource on the session
  /// bridge so DSL `{"type":"resource","action":"subscribe"}` bindings
  /// can read this catalog entry through the spec's resources/read
  /// path (mirrored onto the host's external MCP endpoint via
  /// `resourceServerAdapter`). Idempotent — re-registering the same
  /// URI overwrites the handler.
  void _publishKbResource(String facade, String exposedId) {
    final bridge = _sessionBridge;
    if (bridge == null) return;
    final uri = 'kb://$facade/$exposedId';
    bridge.registerResource(uri, (u) async {
      final value = await bridge.readResource(u);
      if (value == null) return null;
      // Most facade objects expose `toJson()`; fall back to the
      // raw value when not (primitive or already a Map).
      try {
        // ignore: avoid_dynamic_calls
        return (value as dynamic).toJson();
      } catch (_) {
        return value;
      }
    }, mimeType: 'application/json');
    _publishedResourceUris.add(uri);
  }

  /// Track every kb:// URI this context published so unregisterAll
  /// can withdraw them all.
  final List<String> _publishedResourceUris = <String>[];

  @override
  Future<RegistrationResult> registerSkill(mb.SkillModule skill) async {
    final result = await _delegate(
      '$exposedShortId.${skill.id}',
      (a) => a.registerSkill(skill),
    );
    if (result.ok) {
      _registeredSkillIds.add(result.exposedName);
      _publishKbResource('skill', result.exposedName);
    }
    return result;
  }

  @override
  Future<RegistrationResult> registerProfile(
    mb.ProfileDefinition profile,
  ) async {
    final result = await _delegate(
      '$exposedShortId.${profile.id}',
      (a) async => a.registerProfile(profile),
    );
    if (result.ok) {
      _registeredProfileIds.add(result.exposedName);
      _publishKbResource('profile', result.exposedName);
    }
    return result;
  }

  @override
  Future<RegistrationResult> registerPhilosophy(
    mb.Philosophy philosophy,
  ) async {
    final result = await _delegate(
      '$exposedShortId.${philosophy.id}',
      (a) => a.registerPhilosophy(philosophy),
    );
    if (result.ok) {
      _registeredPhilosophyIds.add(result.exposedName);
      _publishKbResource('philosophy', result.exposedName);
    }
    return result;
  }

  @override
  Future<RegistrationResult> registerFact(mb.Fact fact) async {
    final factId =
        fact.id?.trim().isNotEmpty == true
            ? fact.id!
            : '${fact.subject}_${fact.predicate}_${fact.object}'.replaceAll(
              ' ',
              '_',
            );
    final result = await _delegate(
      '$exposedShortId.$factId',
      (a) => a.registerFact(fact),
    );
    if (result.ok) {
      _registeredFactIds.add(result.exposedName);
      _publishKbResource('fact', result.exposedName);
    }
    return result;
  }

  @override
  Future<RegistrationResult> registerFlow(mb.FlowDefinition flow) async {
    final result = await _delegate(
      '$exposedShortId.${flow.id}',
      (a) async => a.registerFlow(flow),
    );
    if (result.ok) {
      _registeredFlowIds.add(result.exposedName);
      // Flow registry is a workflow / pipeline / runbook factory map;
      // expose all three URI shapes for a single flow definition so
      // DSL bindings can read the same id under whichever facade.
      _publishKbResource('workflow', result.exposedName);
      _publishKbResource('pipeline', result.exposedName);
      _publishKbResource('runbook', result.exposedName);
    }
    return result;
  }

  /// Create the per-bundle JS runtime + bridge on first js-tool
  /// registration. Subsequent js tools share the same runtime so
  /// they can call each other and share globals. The runtime lives
  /// inside a dedicated Isolate (see [JsToolIsolate]) so the static
  /// state inside flutter_js 0.8.7 JSCore doesn't stomp other
  /// bundles' bridges.
  Future<JsToolRuntime> _ensureJsRuntime() async {
    final existing = _jsRuntime;
    if (existing != null) return existing;
    final rt = JsToolRuntime();
    final allowedAtoms = bundle.requires?.builtinAtoms ?? const <String>[];
    // The first time this app is seen, its former domain-storage state moves
    // into `kb` before any tool can read it. A failed import leaves the old
    // files where they are and does not stop the bundle.
    final kb = _kb;
    final kbStore = _kbStoreFor(bundle);
    if (kb != null && kbStore != null) {
      try {
        await kb.importLegacyOnce(bundle, kbStore);
      } catch (e) {
        _chromeBridge?.recordBootEvent(
          'kb import for "${bundle.manifest.id}" failed: $e',
        );
      }
    }
    final atoms = _builtinAtomsFor(bundle);
    await rt.attachHostBridge(atoms: atoms, allowedAtoms: allowedAtoms);
    _jsRuntime = rt;
    return rt;
  }

  /// Built-in atoms the host offers to bundles. The bridge filters by
  /// `requires.builtinAtoms` — atoms not declared by the bundle are
  /// not exposed even if listed here. Studio's "rich" set lives here;
  /// AppPlayer-class hosts curate a smaller set, keeping the
  /// portability gradient explicit (memory
  /// `project_studio_appplayer_superset`).
  List<AtomCategory> _builtinAtomsFor(mb.McpBundle b) {
    final dir = b.directory;
    final kbStore = _kbStoreFor(b);
    final cb = _chromeBridge;
    final ws = _activeWorkspace;
    return <AtomCategory>[
      if (dir != null) FsAtom(bundleRoot: dir),
      BundleAtom(bundle: b),
      BusAtom(),
      McpAtom(
        boot: _boot,
        sessionBridge: _sessionBridge,
        sessionResolver: () => _session,
      ),
      AgentAtom(),
      if (kbStore != null) KbAtom(kbStore),
      if (cb != null) UiAtom(bridge: cb),
      // Always register WorkspaceAtom — when the host hasn't wired a
      // canonical provider the atom's own verbs return `{ok:false,
      // reason:'no workspace'}` instead of throwing. JS bundles can
      // call `host.workspace.save()` defensively without first
      // checking for the atom's existence.
      WorkspaceAtom(provider: ws ?? () => null),
    ];
  }

  /// Map a free-form role string to the kernel's `AgentRole` enum.
  /// Bundles can use any role label; unknown values fall back to
  /// `worker` (default executor) so the agent still wires.
  mk.AgentRole _agentRoleFromString(String role) {
    switch (role.toLowerCase()) {
      case 'manager':
        return mk.AgentRole.manager;
      case 'reviewer':
        return mk.AgentRole.reviewer;
      case 'worker':
      default:
        return mk.AgentRole.worker;
    }
  }

  @override
  Future<RegistrationResult> mountUi(UiEntryRef entry) async {
    if (_closed) {
      return const RegistrationResult(
        ok: false,
        exposedName: '',
        error: 'context closed',
      );
    }
    return const RegistrationResult(
      ok: false,
      exposedName: '',
      error: 'mountUi requires Phase 3',
    );
  }

  @override
  Future<void> unregisterAll() async {
    if (_closed) return;
    _closed = true;
    for (final name in _registeredToolNames) {
      try {
        _boot.removeTool(name);
      } catch (_) {
        /* best-effort */
      }
    }
    _registeredToolNames.clear();
    final clients = _clientHost?.call();
    if (clients != null && _mcpConnectionIds.isNotEmpty) {
      for (final connection in clients.connections.toList()) {
        if (!_mcpConnectionIds.contains(connection.id)) continue;
        try {
          await connection.close();
        } catch (_) {
          /* best-effort */
        }
      }
    }
    _mcpConnectionIds.clear();
    final host = AgentHost.shared;
    if (host != null) {
      for (final id in _registeredAgentIds) {
        try {
          await host.removeProfile(id);
        } catch (_) {
          /* best-effort */
        }
      }
    }
    _registeredAgentIds.clear();
    // 4-axis + fact + flow tear-down (knowledge-operations R3). Each
    // category's underlying facade exposes its own unregister API; we
    // call best-effort and continue past failures so the tab close
    // path stays robust.
    final backbone = _backbone;
    if (backbone != null && backbone.isFlowBrainBooted) {
      final system = backbone.app.system;
      for (final id in _registeredProfileIds) {
        try {
          system.profile.unregister(id);
        } catch (_) {
          /* best-effort */
        }
      }
      // Delete the bundle's registered philosophy/ethos entries. The ethos
      // store now exposes an optional delete capability (`EthosStoreDelete`,
      // mcp_bundle >= 0.4.6); when the wired adapter supports it, remove each
      // entry so a deactivated bundle leaves no ethos orphan. Falls back to
      // drop-tracking-only when the adapter lacks delete.
      final ethosStore = system.ethosStore;
      if (ethosStore is mb.EthosStoreDelete &&
          _registeredPhilosophyIds.isNotEmpty) {
        final del = ethosStore as mb.EthosStoreDelete;
        for (final pid in _registeredPhilosophyIds) {
          try {
            await del.deleteEthos(pid);
          } catch (_) {
            /* best-effort — entry may already be absent */
          }
        }
      }
      if (_registeredFactIds.isNotEmpty) {
        try {
          await system.facts.deleteFacts(_registeredFactIds);
        } catch (_) {
          /* best-effort */
        }
      }
      // Skill tear-down — registry has unregisterSkill(id).
      final skillRuntime = system.skillRuntime;
      if (skillRuntime != null) {
        for (final id in _registeredSkillIds) {
          try {
            await skillRuntime.registry.unregisterSkill(id);
          } catch (_) {
            /* best-effort */
          }
        }
      }
      // Flow tear-down — workflowRegistry is a mutable Map, drop the
      // factory entry so listWorkflows stops surfacing this bundle's
      // flow after the tab closes.
      final opsRuntime = system.opsRuntime;
      if (opsRuntime != null) {
        for (final id in _registeredFlowIds) {
          opsRuntime.workflowRegistry.remove(id);
        }
      }
    }
    _registeredSkillIds.clear();
    _registeredProfileIds.clear();
    _registeredPhilosophyIds.clear();
    _registeredFactIds.clear();
    _registeredFlowIds.clear();
    // Withdraw the kb:// resources published for this context so the
    // bridge's serverAdapter can remove them from the external
    // endpoint's resources/list (and the in-process map).
    if (_sessionBridge != null) {
      for (final uri in _publishedResourceUris) {
        try {
          _sessionBridge.unregisterResource(uri);
        } catch (_) {
          /* best-effort */
        }
      }
    }
    _publishedResourceUris.clear();
    // Drop the kernel `BundleActivation` instance from the registry
    // if one was created. Prevents other surfaces (chat dispatch,
    // ops scheduler) from looking up a torn-down catalog via the
    // registry after this tab closes.
    if (_kernelActivation != null) {
      // Close the host-bridge session first so its attached handles
      // (UI mounts / stream subscriptions / scratch resources) are
      // torn down before the catalog they were referencing goes away.
      if (_session != null && _sessionBridge != null) {
        await _sessionBridge.closeSession(_session!);
        _session = null;
      }
      await mk.BundleActivationRegistry.instance.remove(exposedShortId);
      _chromeBridge?.unmapTabBundle(tabKey);
      _kernelActivation = null;
    }
    // Drop the JS runtime + bridge if either was lazily created. The
    // bridge has no separate resources beyond the runtime — disposing
    // the runtime tears down everything it loaded.
    final rt = _jsRuntime;
    if (rt != null) {
      try {
        rt.dispose();
      } catch (_) {
        /* best-effort — quickjs FFI cleanup can be flaky */
      }
    }
    _jsRuntime = null;
  }

  mk.KernelToolResult _errorResult(
    String message, {
    Map<String, dynamic>? extra,
  }) {
    return mk.KernelToolResult(
      content: <mk.KernelContent>[
        mk.KernelTextContent(
          text: jsonEncode(<String, dynamic>{
            'error': message,
            if (extra != null) ...extra,
          }),
        ),
      ],
      isError: true,
    );
  }
}
