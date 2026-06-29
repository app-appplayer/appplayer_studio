/// Example — `appplayer_secure`'s `SecureStorage` as the host `secret.*`
/// keyed credential vault.
///
/// A **different shape from `secure.seal`/`secure.open`** (the stateless,
/// machine-keyed at-rest sealer in `secure_example.dart`): this is a keyed
/// store mapping a `credentialRef` to a secret kept in the OS keychain. An
/// asset (db / homepage / api …) carries only the `credentialRef`; the secret
/// body lives in the vault.
///
/// **No plaintext `get` is exposed.** Vault discipline — a secret is resolved
/// internally when a capability needs it (db connect, browser login), never
/// returned to an agent or the UI. Surfaces set / check (`exists`) / remove /
/// list (keys only).
///
/// Same registration as the other packs:
/// `registerCapabilityTools(registry, capabilityId: secretCapabilityId,
/// tools: secretCapabilityTools(store))`. Like `secure_example.dart` this is
/// Flutter-bound (production storage = platform keychain), hence its home in
/// the `secure_capability` recipe rather than the pure-Dart `capability_tools`.
library;

import 'package:appplayer_secure/appplayer_secure.dart' show SecureStorage;
import 'capability_tool_pack.dart';

/// Capability id (namespace) — exposed names are `secret.set`,
/// `secret.exists`, `secret.remove`, `secret.list`.
const String secretCapabilityId = 'secret';

/// Default keychain namespace for asset credentials — isolated from the
/// identity / at-rest keys the package stores under its own namespaces.
const String defaultCredentialNamespace = 'appplayer.credentials';

String _req(Map<String, dynamic> args, String field) {
  final v = args[field];
  if (v is! String || v.isEmpty) {
    throw CapabilityToolError(
      code: 'secret.bad_input',
      message: '$field (non-empty string) is required',
    );
  }
  return v;
}

/// Build the `secret.*` keyed-vault tool list over a configured [store].
/// [namespace] isolates these credential refs (defaults to
/// [defaultCredentialNamespace]).
List<CapabilityTool> secretCapabilityTools(
  SecureStorage store, {
  String namespace = defaultCredentialNamespace,
}) =>
    <CapabilityTool>[
      CapabilityTool(
        verb: 'set',
        description:
            'Store a secret under a credential ref (overwrites). The value is '
            'never read back in plaintext — only set / checked / removed.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'ref': <String, dynamic>{'type': 'string'},
            'value': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['ref', 'value'],
        },
        invoke: (args) async {
          await store.write(
            _req(args, 'ref'),
            _req(args, 'value'),
            namespace: namespace,
          );
          return const <String, Object?>{'ok': true};
        },
      ),
      CapabilityTool(
        verb: 'exists',
        description: 'Whether a secret is stored under a credential ref.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'ref': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['ref'],
        },
        invoke: (args) async => <String, Object?>{
          'exists': await store.exists(_req(args, 'ref'), namespace: namespace),
        },
      ),
      CapabilityTool(
        verb: 'remove',
        description:
            'Delete the secret stored under a credential ref (idempotent).',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'ref': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['ref'],
        },
        invoke: (args) async {
          await store.delete(_req(args, 'ref'), namespace: namespace);
          return const <String, Object?>{'ok': true};
        },
      ),
      CapabilityTool(
        verb: 'list',
        description: 'List stored credential refs (keys only — never values).',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'prefix': <String, dynamic>{'type': 'string'},
          },
        },
        invoke: (args) async => <String, Object?>{
          'refs': await store.listKeys(
            namespace: namespace,
            prefix: args['prefix'] as String?,
          ),
        },
      ),
    ];
