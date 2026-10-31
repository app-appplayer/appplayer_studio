/// Hub capability — `hub.*` host tools over [HubConnections] (consume) and
/// [HubNodeHost] (expose), plus the adapter that serves the host's own tool
/// surface to a remote caller.
///
/// Every UI action of the hub screens maps to one tool here (1:1), so the
/// workbench LLM, an external Claude and the settings page drive the same
/// path. Host wiring only; no relay or market logic lives in this file.
library;

import 'dart:async';
import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:mcp_client/mcp_client.dart' as mc;
import 'package:mcp_gateway/mcp_gateway.dart';

import 'capability_recipes/capability_recipes.dart';
import 'hub_apps.dart';
import 'hub_connections.dart';
import 'hub_node_host.dart';
import 'hub_space.dart';

const String hubCapabilityId = 'hub';

/// Serves a [mk.KernelServerHost]'s external tools to remote callers.
/// Internal-scope tools never leave the machine.
class KernelHostToolSurface implements LocalToolSurface {
  KernelHostToolSurface(this.host, {this.exclude = const <String>{}});

  final mk.KernelServerHost host;

  /// Tools never offered remotely (e.g. the hub controls themselves).
  final Set<String> exclude;

  bool _served(String name) =>
      !exclude.contains(name) &&
      (host.toolScopes[name] ?? mk.ToolScope.external) == mk.ToolScope.external;

  @override
  Future<List<ToolDefinition>> list() async => [
    for (final d in host.toolDefinitions)
      if (_served(d.name))
        ToolDefinition(
          name: d.name,
          description: d.description,
          inputSchema: d.inputSchema,
        ),
  ];

  @override
  Future<DispatchResult> call(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    if (!_served(name)) {
      return DispatchResult(
        content: [
          {'type': 'text', 'text': '$name is not served to remote callers'},
        ],
        isError: true,
      );
    }
    final r = await host.callTool(name, arguments);
    return DispatchResult(
      content: [
        for (final c in r.content)
          switch (c) {
            mk.KernelTextContent(:final text) => {'type': 'text', 'text': text},
            mk.KernelImageContent(:final data, :final mimeType) => {
              'type': 'image',
              'data': data,
              'mimeType': mimeType,
            },
          },
      ],
      isError: r.isError ?? false,
    );
  }
}

/// Register the `hub.*` tools. [node] may be null on a host that cannot
/// expose itself (no signed-in market account) — those verbs then answer
/// `hub.node_unavailable` instead of being absent.
///
/// Remote hub tools are also published on [registry] as `<namespace>.<tool>`
/// so a model sees them next to the local ones; the set follows connect,
/// select, disconnect and reconnect.
class HubCapability {
  HubCapability({
    required this.registry,
    required this.connections,
    this.node,
    this.space,
  }) {
    toolNames = registerCapabilityTools(
      registry,
      capabilityId: hubCapabilityId,
      tools: _tools(),
    );
    _sub = connections.changes.listen((_) => unawaited(_syncRemoteTools()));
  }

  final mk.HostToolRegistry registry;
  final HubConnections connections;
  final HubNodeHost? node;
  final HubSpace? space;

  StreamSubscription<void>? _sub;
  final Set<String> _published = <String>{};
  Future<void>? _running;
  bool _stale = false;

  /// Tool names of the `hub.*` surface this registered.
  late final List<String> toolNames;

  Future<void> dispose() async {
    await _sub?.cancel();
    for (final name in _published.toList()) {
      final i = name.indexOf('.');
      registry.unregisterExposed(
        bundleId: name.substring(0, i),
        rawName: name.substring(i + 1),
      );
    }
    _published.clear();
  }

  /// Brings the published tools in line with the connections. A burst of
  /// change events runs one pass and at most one more: every pass re-registers
  /// tools, and each registration notifies every open session, so a queue of
  /// passes would keep the host busy long after the events stopped.
  Future<void> _syncRemoteTools() {
    _stale = true;
    return _running ??= _drain().whenComplete(() => _running = null);
  }

  Future<void> _drain() async {
    while (_stale) {
      _stale = false;
      final List<HubToolRef> refs;
      try {
        refs = await connections.tools();
      } catch (_) {
        continue; // a hub mid-reconnect; the next change event re-syncs
      }
      final wanted = {for (final r in refs) r.name: r};
      for (final stale
          in _published.where((n) => !wanted.containsKey(n)).toList()) {
        final i = stale.indexOf('.');
        registry.unregisterExposed(
          bundleId: stale.substring(0, i),
          rawName: stale.substring(i + 1),
        );
        _published.remove(stale);
      }
      for (final ref in wanted.values) {
        if (_published.contains(ref.name)) continue;
        final i = ref.name.indexOf('.');
        registry.registerExposed(
          bundleId: ref.name.substring(0, i),
          rawName: ref.name.substring(i + 1),
          description: ref.description ?? ref.name,
          inputSchema: ref.inputSchema,
          handler: (args) => _callRemote(ref.name, args),
        );
        _published.add(ref.name);
      }
    }
  }

  Future<mk.KernelToolResult> _callRemote(
    String name,
    Map<String, dynamic> args,
  ) async {
    try {
      final r = await connections.call(name, args);
      return mk.KernelToolResult(
        content: [
          for (final c in r.content)
            if (c is mc.TextContent)
              mk.KernelTextContent(text: c.text)
            else
              mk.KernelTextContent(text: jsonEncode(c.toJson())),
        ],
        isError: r.isError ?? false,
      );
    } on HubConnectionError catch (e) {
      return mk.KernelToolResult(
        content: [
          mk.KernelTextContent(
            text: jsonEncode({'ok': false, 'code': e.code, 'error': e.message}),
          ),
        ],
        isError: true,
      );
    }
  }

  Map<String, dynamic> _linkJson(HubLink l) => <String, dynamic>{
    'listingId': l.listingId,
    'title': l.title,
    'namespace': l.namespace,
    'state': l.state.name,
    if (l.error != null) 'error': l.error,
    'tools': l.toolNames,
  };

  HubSpace _space() {
    final s = space;
    if (s == null) {
      throw const CapabilityToolError(
        code: 'hub.node_unavailable',
        message: 'the hub list needs a signed-in market account',
      );
    }
    return s;
  }

  static Map<String, dynamic> _idSchema(String key) => {
    'type': 'object',
    'required': [key],
    'properties': {
      key: {'type': 'string'},
    },
  };

  static String _idArg(Map<String, dynamic> args, String key) {
    final v = args[key];
    if (v is! String || v.isEmpty) {
      throw CapabilityToolError(
        code: 'hub.bad_input',
        message: '$key (non-empty string) is required',
      );
    }
    return v;
  }

  static Map<String, dynamic> _itemJson(HubItem h) => {
    'listingId': h.listingId,
    'title': h.title,
    if (h.icon != null) 'icon': h.icon,
    if (h.description != null) 'description': h.description,
  };

  static Map<String, dynamic> _entryJson(HubEntry e) => {
    'id': e.id,
    'title': e.title,
    if (e.icon != null) 'icon': e.icon,
    'arche': e.isArche,
    'state': e.state.name,
    if (e.error != null) 'error': e.error,
    if (e.nodeId != null) 'nodeId': e.nodeId,
    'apps': [for (final a in e.apps) _appJson(a)],
  };

  static Map<String, dynamic> _appJson(HubAppView a) => {
    'id': a.app.id,
    'name': a.app.name,
    if (a.state != null) 'state': a.state!.name,
    if (a.reason != null) 'reason': a.reason!.name,
    if (a.error != null) 'error': a.error,
    'toolCount': a.toolNames.length,
  };

  static Map<String, dynamic> _appResult(
    HubSpace sp,
    String appId,
    bool reached,
  ) {
    for (final e in sp.entries) {
      for (final a in e.apps) {
        if (a.app.id == appId) {
          return {'ok': true, 'reached': reached, 'app': _appJson(a)};
        }
      }
    }
    return {'ok': true, 'reached': reached, 'appId': appId};
  }

  /// A refused token as a tool error the caller can act on: the code is the
  /// reason, the message is plain.
  static CapabilityToolError _appRefusal(Object e) {
    if (e is HubConnectionError) {
      return CapabilityToolError(code: e.code, message: e.message);
    }
    final reason = hubEntryReasonOf(e);
    return CapabilityToolError(code: 'hub.token_${reason.name}', message: '$e');
  }

  HubNodeHost _node() {
    final n = node;
    if (n == null) {
      throw const CapabilityToolError(
        code: 'hub.node_unavailable',
        message: 'this host cannot expose itself — sign in to the market first',
      );
    }
    return n;
  }

  List<String> _ids(Map<String, dynamic> args) {
    final v = args['listingIds'];
    if (v is! List || v.isEmpty || v.any((e) => e is! String)) {
      throw const CapabilityToolError(
        code: 'hub.bad_input',
        message: 'listingIds (non-empty string array) or all:true is required',
      );
    }
    return v.cast<String>();
  }

  List<CapabilityTool> _tools() => <CapabilityTool>[
    CapabilityTool(
      verb: 'select',
      description:
          'Choose which connected hubs expose tools to the model. '
          'Hubs not listed stay connected but invisible.',
      inputSchema: const {
        'type': 'object',
        'required': ['listingIds'],
        'properties': {
          'listingIds': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
      },
      invoke: (args) async {
        connections.select(_ids(args));
        return {'selected': _ids(args)};
      },
    ),
    CapabilityTool(
      verb: 'disconnect',
      description: 'Drop one hub connection (all:true drops every one).',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'listingId': {'type': 'string'},
          'all': {'type': 'boolean'},
        },
      },
      invoke: (args) async {
        if (args['all'] == true) {
          await connections.disconnectAll();
        } else {
          final id = args['listingId'];
          if (id is! String || id.isEmpty) {
            throw const CapabilityToolError(
              code: 'hub.bad_input',
              message: 'listingId (string) or all:true is required',
            );
          }
          await connections.disconnect(id);
        }
        return {'ok': true};
      },
    ),
    CapabilityTool(
      verb: 'status',
      description:
          'State of every hub connection and of this machine\'s '
          'own node.',
      inputSchema: const {'type': 'object', 'properties': {}},
      invoke:
          (args) async => {
            'connections': [for (final l in connections.links) _linkJson(l)],
            'node':
                node == null
                    ? null
                    : {
                      'state': node!.state.name,
                      if (node!.error != null) 'error': node!.error,
                      'nodeId': node!.nodeId,
                      'sessions': node!.sessions.length,
                    },
          },
    ),
    CapabilityTool(
      verb: 'node_start',
      description:
          'Expose this machine\'s tools on the market hub as a '
          'node. Registers once under the signed-in account; callers must '
          'carry a market-signed token and pass the hub access scope.',
      inputSchema: const {'type': 'object', 'properties': {}},
      invoke: (args) async {
        final n = _node();
        final sp = space;
        if (sp != null) {
          await sp.attach(kArcheHubId);
        } else {
          await n.start();
        }
        return {'state': n.state.name, 'nodeId': n.nodeId};
      },
    ),
    CapabilityTool(
      verb: 'node_stop',
      description:
          'Take this machine\'s node offline (the registration is '
          'kept for the next start).',
      inputSchema: const {'type': 'object', 'properties': {}},
      invoke: (args) async {
        final n = _node();
        final sp = space;
        if (sp != null) {
          await sp.detach(kArcheHubId);
        } else {
          await n.stop();
        }
        return {'state': n.state.name};
      },
    ),
    CapabilityTool(
      verb: 'node_remove',
      description:
          'Remove this machine\'s node from the market for good; '
          'its sessions close and its relay token dies.',
      inputSchema: const {'type': 'object', 'properties': {}},
      invoke: (args) async {
        await _node().unregister();
        return {'ok': true};
      },
    ),
    CapabilityTool(
      verb: 'catalog',
      description:
          'Hubs of the market that are not installed yet '
          '(`type=hub`).',
      inputSchema: const {'type': 'object', 'properties': {}},
      invoke:
          (args) async => {
            'hubs': [for (final h in await _space().find()) _itemJson(h)],
          },
    ),
    CapabilityTool(
      verb: 'installed',
      description:
          'The hub list of this host: Arche first, then the '
          'installed hubs, each with its connection state.',
      inputSchema: const {'type': 'object', 'properties': {}},
      invoke:
          (args) async => {
            'hubs': [for (final e in _space().entries) _entryJson(e)],
          },
    ),
    CapabilityTool(
      verb: 'install',
      description:
          'Install a hub from the market into the hub list. It '
          'joins detached; use hub.attach to put this machine on it.',
      inputSchema: _idSchema('listingId'),
      invoke: (args) async {
        final id = _idArg(args, 'listingId');
        await _space().install(id);
        return {'ok': true, 'listingId': id};
      },
    ),
    CapabilityTool(
      verb: 'hide',
      description:
          'Remove a hub from the list: this machine goes offline '
          'on it, its node is deleted and the item is hidden.',
      inputSchema: _idSchema('listingId'),
      invoke: (args) async {
        final id = _idArg(args, 'listingId');
        await _space().hide(id);
        return {'ok': true, 'listingId': id};
      },
    ),
    CapabilityTool(
      verb: 'attach',
      description:
          'Put this machine online as a node on a hub of the list '
          '(id `arche` for the built-in one) and keep it there.',
      inputSchema: _idSchema('id'),
      invoke: (args) async {
        final id = _idArg(args, 'id');
        await _space().attach(id);
        return _entryJson(_space().entries.firstWhere((e) => e.id == id));
      },
    ),
    CapabilityTool(
      verb: 'detach',
      description: 'Take this machine off a hub of the list.',
      inputSchema: _idSchema('id'),
      invoke: (args) async {
        final id = _idArg(args, 'id');
        await _space().detach(id);
        return _entryJson(_space().entries.firstWhere((e) => e.id == id));
      },
    ),
    CapabilityTool(
      verb: 'nodes',
      description:
          'The nodes of this account on a hub, each connected, '
          'not connected or closed as the hub reports it.',
      inputSchema: _idSchema('id'),
      invoke:
          (args) async => {
            'nodes': [
              for (final n in await _space().nodesOf(_idArg(args, 'id')))
                {
                  'id': n.id,
                  'state': n.state.name,
                  if (n.deployment != null) 'deployment': n.deployment,
                  if (n.hint != null) 'name': n.hint,
                  'heartbeatSec': n.heartbeatSec,
                },
            ],
          },
    ),
    CapabilityTool(
      verb: 'node_release',
      description:
          'Take one of this account\'s nodes off a hub; its open '
          'sessions close with it.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'nodeId': {'type': 'string'},
        },
        'required': ['id', 'nodeId'],
      },
      invoke: (args) async {
        await _space().releaseNode(_idArg(args, 'id'), _idArg(args, 'nodeId'));
        return {'ok': true};
      },
    ),
    CapabilityTool(
      verb: 'heartbeat',
      description:
          'How often the hub checks this machine\'s connection on '
          'a hub, in seconds (0 = never).',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'seconds': {'type': 'integer', 'minimum': 0},
        },
        'required': ['id', 'seconds'],
      },
      invoke: (args) async {
        final sec = args['seconds'];
        if (sec is! int || sec < 0) {
          throw const CapabilityToolError(
            code: 'hub.bad_input',
            message: 'seconds (integer, 0 or more) is required',
          );
        }
        await _space().setHeartbeat(_idArg(args, 'id'), sec);
        return {'ok': true, 'seconds': sec};
      },
    ),
    CapabilityTool(
      verb: 'app_add',
      description:
          'Register an app on an installed hub with the hub '
          'token its owner gave you (hst_…), and open it. A token the hub '
          'refuses is not kept; a good token whose server is not on the '
          'hub right now is kept and opens once the server connects. The '
          'token is held in the OS keychain and is never shown again.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'listingId': {'type': 'string'},
          'token': {'type': 'string'},
          'name': {'type': 'string'},
        },
        'required': ['listingId', 'token'],
      },
      invoke: (args) async {
        final sp = _space();
        final hub = _idArg(args, 'listingId');
        final token = _idArg(args, 'token');
        final name = args['name'];
        try {
          final added = await sp.addApp(hub, name is String ? name : '', token);
          return _appResult(sp, added.app.id, added.reached);
        } on Object catch (e) {
          throw _appRefusal(e);
        }
      },
    ),
    CapabilityTool(
      verb: 'app_token',
      description:
          'Give an app another hub token. The old token stays '
          'when the new one is refused.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'appId': {'type': 'string'},
          'token': {'type': 'string'},
        },
        'required': ['appId', 'token'],
      },
      invoke: (args) async {
        final sp = _space();
        try {
          final added = await sp.changeAppToken(
            _idArg(args, 'appId'),
            _idArg(args, 'token'),
          );
          return _appResult(sp, added.app.id, added.reached);
        } on Object catch (e) {
          throw _appRefusal(e);
        }
      },
    ),
    CapabilityTool(
      verb: 'app_open',
      description:
          'Open a registered app again (for example once its '
          'server is back on the hub).',
      inputSchema: _idSchema('appId'),
      invoke: (args) async {
        final sp = _space();
        final id = _idArg(args, 'appId');
        await sp.openApp(id);
        return _appResult(sp, id, true);
      },
    ),
    CapabilityTool(
      verb: 'app_remove',
      description:
          'Take an app off its hub: it closes and its token is '
          'forgotten.',
      inputSchema: _idSchema('appId'),
      invoke: (args) async {
        final id = _idArg(args, 'appId');
        await _space().removeApp(id);
        return {'ok': true, 'appId': id};
      },
    ),
  ];
}
