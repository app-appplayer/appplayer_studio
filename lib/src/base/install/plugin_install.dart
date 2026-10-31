/// Host install of the **plugin** surface — registers plugins (server / hub /
/// bundle) as first-class `<pluginId>.<tool>` providers in the shared catalog
/// so any app or agent consumes them. Pure host wiring over the vendored
/// `plugin_host` recipe (no kernel change).
///
/// Exposes `plugin.register` / `plugin.unregister` / `plugin.list` on the host
/// registry. Registrations persist to an on-disk file and are re-connected on
/// boot; a registration that cannot be restored stays listed with its reason.
///
/// Registering asks the person once (`plugin` approval, the stored source in
/// full); the answer is kept as a consent bound to that exact source, and boot
/// restore only attaches sources whose consent still matches. Secret option
/// values are never stored: they are referenced from the credential vault
/// (`options.credentialRefs`). Local-subprocess `server` plugins are gated off
/// mobile (no process spawn — same rule as the io process driver).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appplayer_secure/appplayer_secure.dart' show SecureStorage;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'capability_recipes/capability_recipes.dart'
    show
        registerCapabilityTools,
        CapabilityTool,
        CapabilityToolError,
        defaultCredentialNamespace;
import 'host_approval.dart';
import 'plugin_host/plugin_host.dart';

const String pluginCapabilityId = 'plugin';

/// Activate a `bundle` plugin in plugin mode (no UI mount) and return its
/// registered tool raw names. The host supplies this (it owns bundle
/// activation); null leaves bundle plugins unwired.
typedef ActivateBundlePlugin =
    Future<List<String>> Function(PluginSource source);

/// Tear a `bundle` plugin's activation fully down (tools + resources + isolate).
typedef DeactivateBundlePlugin = Future<void> Function(String id);

/// Option names that carry secrets; their values belong in the vault.
final RegExp _secretKey = RegExp(
  r'token|secret|passw|authorization|api[-_]?key|credential|bearer',
  caseSensitive: false,
);

/// Register `plugin.*` on [registry]. [clientHost] is required for server/hub
/// plugins (the host's outbound `KernelClientHost`); bundle plugins use
/// [activateBundle]/[deactivateBundle] (the host owns bundle activation).
/// [storePath] overrides the persistence file (tests).
///
/// [approver] is asked once per registration (`plugin`). A host with nobody to
/// ask passes none and registration is refused, unless it states the policy
/// explicitly with [preApproved]. [adoptUnconsented]: a registration stored
/// before consents were kept (no consent at all — not one that no longer
/// matches) is attached once and given a consent by policy, so a host that
/// used to register without asking does not lose its plugins when it starts
/// asking. [accessProvider] is the host's door for
/// door-issued (`hub` with a `ref`) sources; without it those are refused.
/// [vault] resolves `options.credentialRefs` when a source connects.
/// [isNamespaceTaken] lets the host add its own reserved names.
List<String> registerPluginTools(
  mk.HostToolRegistry registry, {
  mk.KernelClientHost? clientHost,
  String? storePath,
  ActivateBundlePlugin? activateBundle,
  DeactivateBundlePlugin? deactivateBundle,
  PluginAccessProvider? accessProvider,
  bool Function(String namespace)? isNamespaceTaken,
  SecureStorage? vault,
  HostApprover? approver,
  bool preApproved = false,
  bool adoptUnconsented = false,
}) {
  final host = PluginHost(
    registry,
    clientHost: clientHost,
    accessProvider: accessProvider,
    isNamespaceTaken: isNamespaceTaken,
  );
  final store = _PluginStore(storePath ?? _defaultStorePath());
  final ctx = _Ctx(
    host: host,
    store: store,
    registry: registry,
    activateBundle: activateBundle,
    deactivateBundle: deactivateBundle,
    accessProvider: accessProvider,
    vault: vault,
    approver: approver,
    preApproved: preApproved,
    adoptUnconsented: adoptUnconsented,
  );

  // Re-connect/re-activate persisted plugins. Fire-and-forget: boot must not
  // block on external endpoints, and a dead endpoint must not break startup.
  unawaited(_restore(ctx));

  return registerCapabilityTools(
    registry,
    capabilityId: pluginCapabilityId,
    tools: <CapabilityTool>[
      CapabilityTool(
        verb: 'register',
        description:
            'Register a plugin (server / hub / bundle) so its tools enter the '
            'catalog as `<id>.<tool>` for any app/agent. The person is asked '
            'once; server/hub connect immediately; the registration persists '
            'and re-connects on boot. Secret option values are referenced '
            'from the vault with options.credentialRefs, never passed inline.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{
              'type': 'string',
              'description':
                  'Stable id = the tool namespace (`<id>.<tool>`). No dots.',
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
              'description':
                  'URL (network), bundle location (bundle) or command '
                  '(local subprocess).',
            },
            'ref': <String, dynamic>{
              'type': 'string',
              'description':
                  'hub: the market listing the door issues access for. No '
                  'address or token is stored.',
            },
            'tools': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
              'description':
                  'Allow-list of the server\'s tool names to mirror. Absent = '
                  'every tool the server lists.',
            },
            'destructiveTools': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
              'description':
                  'Tool names registered as destructive (human confirm).',
            },
            'name': <String, dynamic>{'type': 'string'},
            'description': <String, dynamic>{'type': 'string'},
            'options': <String, dynamic>{
              'type': 'object',
              'description':
                  'Transport options. `credentialRefs` maps an option path '
                  '(e.g. `accessToken`, `headers.X-Api-Key`) to a vault '
                  'credential ref.',
            },
          },
          'required': <String>['id', 'kind'],
        },
        invoke: (args) => _guard(() => _register(ctx, args)),
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
          await _deactivateIfBundle(ctx, id);
          await host.unregister(id);
          await store.remove(id);
          return <String, Object?>{'ok': true, 'id': id};
        },
      ),
      CapabilityTool(
        verb: 'reconnect',
        description:
            'Try a registered plugin again now (not asked): connect, bring '
            'the mirror in line with the server\'s tool list, or report why '
            'it cannot. A registration whose approval no longer matches is '
            'not attached.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['id'],
        },
        invoke: (args) async {
          final id = _req(args, 'id');
          final entry = (await store.load()).where((e) => e.source.id == id);
          if (entry.isEmpty) {
            throw CapabilityToolError(
              code: 'plugin.bad_input',
              message: 'no registered plugin "$id"',
            );
          }
          await _attach(ctx, entry.first);
          final reg = host.plugin(id)!;
          return <String, Object?>{
            'ok': reg.isConnected,
            'id': id,
            'status': reg.isConnected ? 'connected' : 'unavailable',
            'tools': reg.exposedNames,
            if (reg.unavailable != null)
              'unavailable': <String, Object?>{
                'wire': reg.unavailable!.wire,
                if (reg.detail.isNotEmpty) 'detail': reg.detail,
              },
          };
        },
      ),
      CapabilityTool(
        verb: 'list',
        description:
            'List registered plugins with their id, kind, status and exposed '
            'tools. A plugin that cannot serve right now is still listed, with '
            'the reason.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        invoke:
            (args) async => <String, Object?>{
              'plugins': <Map<String, Object?>>[
                for (final reg in host.plugins)
                  <String, Object?>{
                    'id': reg.source.id,
                    'kind': reg.source.kind.name,
                    'status': reg.isConnected ? 'connected' : 'unavailable',
                    'tools': reg.exposedNames,
                    if (reg.unavailable != null)
                      'unavailable': <String, Object?>{
                        'wire': reg.unavailable!.wire,
                        if (reg.detail.isNotEmpty) 'detail': reg.detail,
                      },
                  },
              ],
            },
      ),
    ],
  );
}

class _Ctx {
  _Ctx({
    required this.host,
    required this.store,
    required this.registry,
    required this.activateBundle,
    required this.deactivateBundle,
    required this.accessProvider,
    required this.vault,
    required this.approver,
    required this.preApproved,
    required this.adoptUnconsented,
  });

  final PluginHost host;
  final _PluginStore store;
  final mk.HostToolRegistry registry;
  final ActivateBundlePlugin? activateBundle;
  final DeactivateBundlePlugin? deactivateBundle;
  final PluginAccessProvider? accessProvider;
  final SecureStorage? vault;
  final HostApprover? approver;
  final bool preApproved;
  final bool adoptUnconsented;
}

/// Turns the recipe's [PluginError] into the capability error envelope.
Future<Map<String, Object?>> _guard(
  Future<Map<String, Object?>> Function() body,
) async {
  try {
    return await body();
  } on PluginError catch (e) {
    throw CapabilityToolError(code: e.code, message: e.message);
  }
}

Future<Map<String, Object?>> _register(
  _Ctx c,
  Map<String, dynamic> args,
) async {
  final source = _sourceFromArgs(args);
  _checkInput(c, source);
  _gatePlatform(source);
  if (source.kind == PluginKind.bundle && c.activateBundle == null) {
    throw CapabilityToolError(
      code: 'plugin.bundle_unwired',
      message:
          'this host did not wire bundle-plugin activation '
          '(activateBundle). server/hub are available.',
    );
  }
  if (source.isDoorIssued && c.accessProvider == null) {
    throw CapabilityToolError(
      code: 'plugin.market_unavailable',
      message: 'this host has no connection door for door-issued plugins',
    );
  }
  // Resolving checks every referenced credential exists before the person is
  // asked, so a request is never approved only to fail on a missing secret.
  await _resolveSecrets(c, source);
  final consent = await _approve(c, source);

  await _deactivateIfBundle(c, source.id);
  final RegisteredPlugin reg;
  if (source.kind == PluginKind.bundle) {
    // The host activates the bundle in plugin mode (no UI) — that registers
    // its tools under the id; record them for lifecycle.
    final names = await c.activateBundle!(source);
    reg = c.host.registerBundle(source, toolRawNames: names);
  } else {
    reg = await c.host.registerServer(await _resolveSecrets(c, source));
  }
  await c.store.put(source, consent);
  return <String, Object?>{
    'ok': true,
    'id': source.id,
    'kind': source.kind.name,
    'tools': reg.exposedNames,
  };
}

/// Refuses what can never register, before anybody is asked.
void _checkInput(_Ctx c, PluginSource source) {
  final id = source.id;
  if (id.contains('.') || id.trim() != id) {
    throw CapabilityToolError(
      code: 'plugin.bad_input',
      message: 'id must be a name without dots or surrounding spaces',
    );
  }
  if (source.kind == PluginKind.hub &&
      source.ref == null &&
      (source.endpoint ?? '').isEmpty) {
    throw CapabilityToolError(
      code: 'plugin.bad_input',
      message: 'a hub plugin needs a ref (listing) or an endpoint',
    );
  }
  if (source.kind == PluginKind.bundle && (source.endpoint ?? '').isEmpty) {
    throw CapabilityToolError(
      code: 'plugin.bad_input',
      message: 'a bundle plugin needs the bundle location in endpoint',
    );
  }
  final options = source.options;
  final env = options?['env'];
  if (env != null &&
      (env is! Map ||
          env.values.any((v) => v is! String) ||
          source.transport != mk.KernelTransportKind.stdio)) {
    throw CapabilityToolError(
      code: 'plugin.bad_input',
      message:
          'options.env is a map of strings and only a stdio plugin has one',
    );
  }
  if (options != null) {
    final inline = _inlineSecretPath(options);
    if (inline != null) {
      throw CapabilityToolError(
        code: 'plugin.bad_input',
        message:
            'options.$inline looks like a secret; store it in the vault and '
            'reference it with options.credentialRefs',
      );
    }
  }
  if (c.host.plugin(id) == null) {
    final taken = c.registry.endpoint.toolDefinitions.any(
      (d) => d.name.startsWith('$id.'),
    );
    if (taken) {
      throw CapabilityToolError(
        code: 'plugin.id_taken',
        message: 'tools named "$id.*" already exist',
      );
    }
  }
}

/// The dotted path of the first option key that looks like a secret and
/// carries a plain value, or null. `credentialRefs` holds references only.
String? _inlineSecretPath(Map<String, dynamic> options, [String prefix = '']) {
  for (final e in options.entries) {
    if (e.key == 'credentialRefs') continue;
    final path = prefix.isEmpty ? e.key : '$prefix.${e.key}';
    final v = e.value;
    if (v is Map<String, dynamic>) {
      final inner = _inlineSecretPath(v, path);
      if (inner != null) return inner;
    } else if (_secretKey.hasMatch(e.key) && v != null && '$v'.isNotEmpty) {
      return path;
    }
  }
  return null;
}

/// [source] with its `credentialRefs` replaced by the vault values. The
/// result lives in memory only; the stored source keeps the references.
Future<PluginSource> _resolveSecrets(_Ctx c, PluginSource source) async {
  final options = source.options;
  final refs = options?['credentialRefs'];
  if (options == null || refs == null) return source;
  if (refs is! Map) {
    throw CapabilityToolError(
      code: 'plugin.bad_input',
      message: 'options.credentialRefs must map an option path to a ref',
    );
  }
  final vault = c.vault;
  if (vault == null) {
    throw CapabilityToolError(
      code: 'plugin.bad_input',
      message: 'this host has no credential vault for options.credentialRefs',
    );
  }
  final resolved = _deepCopy(options)..remove('credentialRefs');
  for (final e in refs.entries) {
    final ref = e.value;
    if (ref is! String || ref.isEmpty) {
      throw CapabilityToolError(
        code: 'plugin.bad_input',
        message: 'credentialRefs["${e.key}"] must be a vault ref',
      );
    }
    final value = await vault.read(ref, namespace: defaultCredentialNamespace);
    if (value == null) {
      throw CapabilityToolError(
        code: 'plugin.bad_input',
        message: 'credential ref "$ref" is not in the vault',
      );
    }
    _setPath(resolved, '${e.key}'.split('.'), value);
  }
  return PluginSource(
    id: source.id,
    kind: source.kind,
    name: source.name,
    description: source.description,
    transport: source.transport,
    endpoint: source.endpoint,
    options: resolved,
    ref: source.ref,
    tools: source.tools,
    destructiveTools: source.destructiveTools,
  );
}

Map<String, dynamic> _deepCopy(Map<String, dynamic> m) =>
    (jsonDecode(jsonEncode(m)) as Map).cast<String, dynamic>();

void _setPath(Map<String, dynamic> into, List<String> path, Object value) {
  var at = into;
  for (var i = 0; i < path.length - 1; i++) {
    final next = at[path[i]];
    if (next is Map<String, dynamic>) {
      at = next;
    } else {
      final made = <String, dynamic>{};
      at[path[i]] = made;
      at = made;
    }
  }
  at[path.last] = value;
}

/// Asks the person (`plugin`) and returns the consent to keep with the
/// stored source. No asker and no stated policy is a refusal.
Future<_Consent> _approve(_Ctx c, PluginSource source) async {
  if (c.preApproved) {
    return _Consent(_fingerprint(source), 'preapproved-policy', DateTime.now());
  }
  final asker = c.approver;
  if (asker == null) {
    throw CapabilityToolError(
      code: 'plugin.not_approved',
      message: 'this host has nobody to ask, so no plugin can be registered',
    );
  }
  final record = await asker.request(
    ApprovalRequest(
      kind: 'plugin',
      summary: _summary(source),
      origin: 'plugin.register',
      risk:
          source.kind == PluginKind.server && !source.isNetwork
              ? 'Starts a program on this machine and puts its tools where '
                  'agents can reach them.'
              : 'Puts another app\'s tools where agents can reach them.',
    ),
  );
  if (!record.approved) {
    throw CapabilityToolError(
      code: 'plugin.not_approved',
      message: 'registration was not approved (${record.reason})',
    );
  }
  return _Consent(_fingerprint(source), record.approver, record.at);
}

/// What the person is shown: kind, id, where it comes from, the whole command
/// for a local process, and what is let through.
String _summary(PluginSource s) {
  final where = switch (s.kind) {
    PluginKind.bundle => 'bundle ${s.endpoint}',
    PluginKind.hub when s.ref != null =>
      'listing ${s.ref} (access issued by '
          'the door on every connect)',
    _ when !s.isNetwork && s.transport == mk.KernelTransportKind.stdio =>
      'start "${_command(s)}"',
    _ => '${s.transport?.name ?? 'streamableHttp'} ${s.endpoint}',
  };
  final tools =
      s.tools == null
          ? 'every tool the server lists'
          : 'only ${s.tools!.join(', ')}';
  final destructive =
      (s.destructiveTools ?? const <String>[]).isEmpty
          ? ''
          : '; confirm before ${s.destructiveTools!.join(', ')}';
  final options = s.options;
  final refs = options?['credentialRefs'];
  final secrets =
      refs is Map && refs.isNotEmpty
          ? '; vault refs: ${refs.entries.map((e) => '${e.key}=${e.value}').join(', ')}'
          : '';
  final envNames = <String>{
    if (options?['env'] is Map)
      ...(options!['env'] as Map).keys.map((k) => '$k'),
    if (refs is Map)
      for (final k in refs.keys)
        if ('$k'.startsWith('env.')) '$k'.substring(4),
  };
  final env = envNames.isEmpty ? '' : '; environment: ${envNames.join(', ')}';
  return 'Register ${s.kind.name} plugin "${s.id}": $where; $tools$destructive'
      '$env$secrets.';
}

String _command(PluginSource s) {
  final o = s.options ?? const <String, dynamic>{};
  final command = (o['command'] as String?) ?? s.endpoint ?? '';
  final args = (o['args'] as List?)?.join(' ') ?? '';
  return '$command $args'.trim();
}

class _Consent {
  const _Consent(this.fingerprint, this.by, this.at);
  final String fingerprint;
  final String by;
  final DateTime at;
}

/// Hash of everything the person approved. Name and description are labels,
/// not part of what runs, so they may change without a new question.
String _fingerprint(PluginSource s) {
  final canonical = _canonical(<String, Object?>{
    'id': s.id,
    'kind': s.kind.name,
    'transport': s.transport?.name,
    'endpoint': s.endpoint,
    'options': s.options,
    'ref': s.ref,
    'tools': s.tools,
    'destructiveTools': s.destructiveTools,
  });
  return crypto.sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
}

Object? _canonical(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    return <String, Object?>{for (final k in keys) k: _canonical(v[k])};
  }
  if (v is List) return <Object?>[for (final e in v) _canonical(e)];
  return v;
}

Future<void> _deactivateIfBundle(_Ctx c, String id) async {
  final existing = c.host.plugin(id);
  if (existing != null &&
      existing.source.kind == PluginKind.bundle &&
      c.deactivateBundle != null) {
    try {
      await c.deactivateBundle!(id);
    } on Object {
      // Tearing down an activation that never completed must not block the
      // removal or the replacement.
    }
  }
}

Future<void> _restore(_Ctx c) async {
  for (final entry in await c.store.load()) {
    await _attach(c, entry);
  }
}

/// Brings one stored registration up, or keeps it listed with the reason it
/// cannot be. Used at boot and by `plugin.reconnect`; it never asks.
Future<void> _attach(_Ctx c, _Stored entry) async {
  final source = entry.source;
  try {
    if (!c.preApproved && c.adoptUnconsented && entry.consent == null) {
      // Registered before consents existed: adopt it once, on record.
      await c.store.put(
        source,
        _Consent(
          _fingerprint(source),
          'adopted-earlier-registration',
          DateTime.now(),
        ),
      );
    } else if (!c.preApproved &&
        entry.consent?.fingerprint != _fingerprint(source)) {
      c.host.markUnavailable(
        source,
        PluginUnavailable.notApproved,
        detail: 'no recorded approval covers the stored registration',
      );
      return;
    }
    _gatePlatform(source);
    if (source.kind == PluginKind.bundle) {
      final activate = c.activateBundle;
      if (activate == null) {
        c.host.markUnavailable(
          source,
          PluginUnavailable.gated,
          detail: 'this host did not wire bundle-plugin activation',
        );
        return;
      }
      try {
        await _deactivateIfBundle(c, source.id);
        final names = await activate(source);
        c.host.registerBundle(source, toolRawNames: names);
      } on Object catch (e) {
        c.host.markUnavailable(
          source,
          PluginUnavailable.bundleMissing,
          detail: '$e',
        );
      }
      return;
    }
    if (source.isDoorIssued && c.accessProvider == null) {
      c.host.markUnavailable(
        source,
        PluginUnavailable.gated,
        detail: 'this host has no connection door for door-issued plugins',
      );
      return;
    }
    await c.host.registerServer(await _resolveSecrets(c, source));
  } on PluginAccessException catch (e) {
    c.host.markUnavailable(source, e.reason, detail: e.message);
  } on CapabilityToolError catch (e) {
    c.host.markUnavailable(
      source,
      e.code == 'plugin.platform_unsupported'
          ? PluginUnavailable.gated
          : PluginUnavailable.unreachable,
      detail: e.message,
    );
  } on Object catch (e) {
    // A dead endpoint stays registered with its reason and tries again on the
    // next boot.
    c.host.markUnavailable(source, PluginUnavailable.unreachable, detail: '$e');
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
    orElse:
        () =>
            throw CapabilityToolError(
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
    ref: args['ref'] as String?,
    tools: _names(args['tools']),
    destructiveTools: _names(args['destructiveTools']),
  );
}

List<String>? _names(Object? v) =>
    v is List ? <String>[for (final e in v) '$e'] : null;

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

/// Fallback on-disk plugin registry — `~/.config/appplayer/plugins.json`.
/// Only used when the caller passes no [storePath] (e.g. tests). The Studio
/// host ALWAYS overrides this with a per-instance, toolId-scoped path
/// (`~/.config/<toolId>/plugins.json`) so the debug / release / pro instances
/// never share plugin state — see `registerPluginTools` call in
/// `vibe_studio_host_app.dart`. Persists all kinds: server/hub re-connect from
/// the endpoint, bundle re-activates from its local `.mbd` path on boot.
String _defaultStorePath() {
  final home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
  return p.join(home, '.config', 'appplayer', 'plugins.json');
}

class _Stored {
  const _Stored(this.source, this.consent);
  final PluginSource source;
  final _Consent? consent;
}

class _PluginStore {
  _PluginStore(this.path);
  final String path;

  Future<List<_Stored>> load() async {
    try {
      final f = File(path);
      if (!await f.exists()) return const <_Stored>[];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return const <_Stored>[];
      return <_Stored>[
        for (final e in raw)
          if (e is Map<String, dynamic>) _fromJson(e),
      ];
    } catch (_) {
      return const <_Stored>[];
    }
  }

  Future<void> put(PluginSource source, _Consent consent) async {
    final all =
        (await load()).where((s) => s.source.id != source.id).toList()
          ..add(_Stored(source, consent));
    await _save(all);
  }

  Future<void> remove(String id) async {
    final all = (await load()).where((s) => s.source.id != id).toList();
    await _save(all);
  }

  Future<void> _save(List<_Stored> stored) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    final tmp = File('$path.$pid.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(<Map<String, Object?>>[for (final s in stored) _toJson(s)]),
      flush: true,
    );
    await tmp.rename(path);
  }

  static Map<String, Object?> _toJson(_Stored st) {
    final s = st.source;
    return <String, Object?>{
      'id': s.id,
      'kind': s.kind.name,
      'name': s.name,
      'description': s.description,
      if (s.transport != null) 'transport': s.transport!.name,
      if (s.endpoint != null) 'endpoint': s.endpoint,
      if (s.options != null) 'options': s.options,
      if (s.ref != null) 'ref': s.ref,
      if (s.tools != null) 'tools': s.tools,
      if (s.destructiveTools != null) 'destructiveTools': s.destructiveTools,
      if (st.consent != null)
        'consent': <String, Object?>{
          'fingerprint': st.consent!.fingerprint,
          'by': st.consent!.by,
          'at': st.consent!.at.toUtc().toIso8601String(),
        },
    };
  }

  static _Stored _fromJson(Map<String, dynamic> j) {
    final c = j['consent'];
    return _Stored(
      PluginSource(
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
        ref: j['ref'] as String?,
        tools: _names(j['tools']),
        destructiveTools: _names(j['destructiveTools']),
      ),
      c is Map && c['fingerprint'] is String
          ? _Consent(
            c['fingerprint'] as String,
            (c['by'] as String?) ?? '',
            DateTime.tryParse('${c['at']}') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          )
          : null,
    );
  }
}
