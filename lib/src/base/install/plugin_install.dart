/// Host install of the **plugin** surface — registers plugins (server / hub /
/// bundle) as first-class `<pluginId>.<tool>` providers in the shared catalog
/// so any app or agent consumes them. Pure host wiring over the vendored
/// `plugin_host` recipe (no kernel change).
///
/// Exposes `plugin.register` / `plugin.unregister` / `plugin.list` on the host
/// registry. Server/hub plugins persist to a **shared** on-disk file so a
/// plugin registered in Studio is available to any AppPlayer host on the same
/// machine (desktop), and are re-connected on boot. Local-subprocess `server`
/// plugins are gated off mobile (no process spawn — same rule as the io
/// process driver).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:path/path.dart' as p;

import 'capability_recipes/capability_recipes.dart'
    show registerCapabilityTools, CapabilityTool, CapabilityToolError;
import 'plugin_host/plugin_host.dart';

const String pluginCapabilityId = 'plugin';

/// Activate a `bundle` plugin in plugin mode (no UI mount) and return its
/// registered tool raw names. The host supplies this (it owns bundle
/// activation); null leaves bundle plugins unwired.
typedef ActivateBundlePlugin = Future<List<String>> Function(PluginSource source);

/// Tear a `bundle` plugin's activation fully down (tools + resources + isolate).
typedef DeactivateBundlePlugin = Future<void> Function(String id);

/// Register `plugin.*` on [registry]. [clientHost] is required for server/hub
/// plugins (the host's outbound `KernelClientHost`); bundle plugins use
/// [activateBundle]/[deactivateBundle] (the host owns bundle activation).
/// [storePath] overrides the shared persistence file (tests).
List<String> registerPluginTools(
  mk.HostToolRegistry registry, {
  mk.KernelClientHost? clientHost,
  String? storePath,
  ActivateBundlePlugin? activateBundle,
  DeactivateBundlePlugin? deactivateBundle,
}) {
  final host = PluginHost(registry, clientHost: clientHost);
  final store = _PluginStore(storePath ?? _defaultStorePath());

  // Re-connect/re-activate persisted plugins. Fire-and-forget: boot must not
  // block on external endpoints, and a dead endpoint must not break startup.
  unawaited(_restore(host, store, activateBundle));

  return registerCapabilityTools(
    registry,
    capabilityId: pluginCapabilityId,
    tools: <CapabilityTool>[
      CapabilityTool(
        verb: 'register',
        description:
            'Register a plugin (server / hub / bundle) so its tools enter the '
            'catalog as `<id>.<tool>` for any app/agent. server/hub connect '
            'immediately; the registration persists and re-connects on boot.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{
              'type': 'string',
              'description': 'Stable id = the tool namespace (`<id>.<tool>`).',
            },
            'kind': <String, dynamic>{
              'type': 'string',
              'enum': <String>['server', 'hub', 'bundle'],
            },
            'transport': <String, dynamic>{
              'type': 'string',
              'description':
                  'server/hub: streamableHttp | sse | stdio. Defaults to '
                  'streamableHttp.',
            },
            'endpoint': <String, dynamic>{
              'type': 'string',
              'description': 'URL (network) or command (local subprocess).',
            },
            'name': <String, dynamic>{'type': 'string'},
            'description': <String, dynamic>{'type': 'string'},
            'options': <String, dynamic>{'type': 'object'},
          },
          'required': <String>['id', 'kind'],
        },
        invoke: (args) async {
          final source = _sourceFromArgs(args);
          _gatePlatform(source);
          final RegisteredPlugin reg;
          if (source.kind == PluginKind.bundle) {
            if (activateBundle == null) {
              throw CapabilityToolError(
                code: 'plugin.bundle_unwired',
                message:
                    'this host did not wire bundle-plugin activation '
                    '(activateBundle). server/hub are available.',
              );
            }
            // The host activates the bundle in plugin mode (no UI) — that
            // registers its tools under the id; record them for lifecycle.
            final names = await activateBundle(source);
            reg = host.registerBundle(source, toolRawNames: names);
          } else {
            reg = await host.registerServer(source);
          }
          await store.put(source);
          return <String, Object?>{
            'ok': true,
            'id': source.id,
            'kind': source.kind.name,
            'tools': reg.exposedNames,
          };
        },
      ),
      CapabilityTool(
        verb: 'unregister',
        description:
            'Remove a plugin: tear its `<id>.*` catalog entries down and close '
            'the connection.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['id'],
        },
        invoke: (args) async {
          final id = _req(args, 'id');
          // Bundle plugins need a full activation teardown (tools + resources
          // + isolate); server/hub need `unregister` (unregisterExposed +
          // close). Both then drop from the registry + store.
          if (host.plugin(id)?.source.kind == PluginKind.bundle &&
              deactivateBundle != null) {
            await deactivateBundle(id);
          }
          await host.unregister(id);
          await store.remove(id);
          return <String, Object?>{'ok': true, 'id': id};
        },
      ),
      CapabilityTool(
        verb: 'list',
        description:
            'List registered plugins with their id, kind, and exposed tools.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        invoke: (args) async => <String, Object?>{
          'plugins': <Map<String, Object?>>[
            for (final reg in host.plugins)
              <String, Object?>{
                'id': reg.source.id,
                'kind': reg.source.kind.name,
                'tools': reg.exposedNames,
              },
          ],
        },
      ),
    ],
  );
}

Future<void> _restore(
  PluginHost host,
  _PluginStore store,
  ActivateBundlePlugin? activateBundle,
) async {
  for (final source in await store.load()) {
    try {
      _gatePlatform(source);
      if (source.kind == PluginKind.bundle) {
        if (activateBundle == null) continue;
        final names = await activateBundle(source);
        host.registerBundle(source, toolRawNames: names);
      } else {
        await host.registerServer(source);
      }
    } catch (_) {
      // A dead/blocked endpoint, a missing bundle, or a gated source is
      // skipped — it stays persisted and re-tries next boot.
    }
  }
}

void _gatePlatform(PluginSource source) {
  if (source.kind == PluginKind.server &&
      !source.isNetwork &&
      (Platform.isIOS || Platform.isAndroid)) {
    throw CapabilityToolError(
      code: 'plugin.platform_unsupported',
      message:
          'a local-subprocess server plugin needs process spawn — desktop '
          'only. Use a network endpoint (streamableHttp/sse) for mobile.',
    );
  }
}

PluginSource _sourceFromArgs(Map<String, dynamic> args) {
  final id = _req(args, 'id');
  final kind = PluginKind.values.firstWhere(
    (k) => k.name == args['kind'],
    orElse: () => throw CapabilityToolError(
      code: 'plugin.bad_input',
      message: 'kind must be server | hub | bundle',
    ),
  );
  return PluginSource(
    id: id,
    kind: kind,
    name: (args['name'] as String?) ?? '',
    description: (args['description'] as String?) ?? '',
    transport: _transportFromName(args['transport'] as String?),
    endpoint: args['endpoint'] as String?,
    options: (args['options'] as Map?)?.cast<String, dynamic>(),
  );
}

mk.KernelTransportKind? _transportFromName(String? name) {
  if (name == null || name.isEmpty) return null;
  for (final t in mk.KernelTransportKind.values) {
    if (t.name == name) return t;
  }
  return null;
}

String _req(Map<String, dynamic> args, String field) {
  final v = args[field];
  if (v is! String || v.isEmpty) {
    throw CapabilityToolError(
      code: 'plugin.bad_input',
      message: '$field (non-empty string) is required',
    );
  }
  return v;
}

/// Shared on-disk plugin registry — `~/.config/appplayer/plugins.json` (a
/// neutral `appplayer` namespace, not Studio-specific, so any AppPlayer host on
/// the machine reads the same list). Persists all kinds: server/hub re-connect
/// from the endpoint, bundle re-activates from its local `.mbd` path on boot.
String _defaultStorePath() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return p.join(home, '.config', 'appplayer', 'plugins.json');
}

class _PluginStore {
  _PluginStore(this.path);
  final String path;

  Future<List<PluginSource>> load() async {
    try {
      final f = File(path);
      if (!await f.exists()) return const <PluginSource>[];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return const <PluginSource>[];
      return <PluginSource>[
        for (final e in raw)
          if (e is Map<String, dynamic>) _fromJson(e),
      ];
    } catch (_) {
      return const <PluginSource>[];
    }
  }

  Future<void> put(PluginSource source) async {
    final all = (await load()).where((s) => s.id != source.id).toList()
      ..add(source);
    await _save(all);
  }

  Future<void> remove(String id) async {
    final all = (await load()).where((s) => s.id != id).toList();
    await _save(all);
  }

  Future<void> _save(List<PluginSource> sources) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert(
        <Map<String, Object?>>[for (final s in sources) _toJson(s)],
      ),
    );
  }

  static Map<String, Object?> _toJson(PluginSource s) => <String, Object?>{
        'id': s.id,
        'kind': s.kind.name,
        'name': s.name,
        'description': s.description,
        if (s.transport != null) 'transport': s.transport!.name,
        if (s.endpoint != null) 'endpoint': s.endpoint,
        if (s.options != null) 'options': s.options,
      };

  static PluginSource _fromJson(Map<String, dynamic> j) => PluginSource(
        id: j['id'] as String,
        kind: PluginKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => PluginKind.server,
        ),
        name: (j['name'] as String?) ?? '',
        description: (j['description'] as String?) ?? '',
        transport: _transportFromName(j['transport'] as String?),
        endpoint: j['endpoint'] as String?,
        options: (j['options'] as Map?)?.cast<String, dynamic>(),
      );
}
