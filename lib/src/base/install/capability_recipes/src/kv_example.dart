/// Example — the canonical file KV (`KvStoragePortAdapter`) as capability
/// tools.
///
/// Shape B: brain_kernel ships a single file-backed `KvStoragePort`
/// implementation (`KvStoragePortAdapter`, with optional workspace-scope
/// enforcement). This example wraps its operations per-verb so a host can
/// embed `kv.*` — replacing bespoke per-tool KV adapters. The host owns a
/// configured instance (rootDir + optional workspaceId) and calls
/// `registerCapabilityTools(registry, capabilityId: 'kv', tools:
/// kvCapabilityTools(adapter))`.
library;

import 'package:brain_kernel/brain_kernel.dart';

import 'capability_tool_pack.dart';

/// Capability id (namespace) — exposed names are `kv.get`, `kv.set`, ….
const String kvCapabilityId = 'kv';

/// Build the kv capability's tool list over a configured
/// [KvStoragePortAdapter]. Scope enforcement (when the adapter carries a
/// `workspaceId`) surfaces as a boundary error, never a host throw.
List<CapabilityTool> kvCapabilityTools(KvStoragePortAdapter kv) {
  const keyProp = <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'key': <String, dynamic>{'type': 'string'},
    },
    'required': <String>['key'],
  };
  String requireKey(Map<String, dynamic> args) {
    final key = args['key'];
    if (key is! String || key.isEmpty) {
      throw const CapabilityToolError(
        code: 'kv.bad_input',
        message: 'key (non-empty string) is required',
      );
    }
    return key;
  }

  return <CapabilityTool>[
    CapabilityTool(
      verb: 'set',
      description: 'Store a JSON-serializable value under a key.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'key': <String, dynamic>{'type': 'string'},
          'value': <String, dynamic>{
            'description': 'JSON-serializable value to store.',
          },
        },
        'required': <String>['key', 'value'],
      },
      invoke: (args) async {
        await kv.set(requireKey(args), args['value']);
        return <String, dynamic>{'ok': true};
      },
    ),
    CapabilityTool(
      verb: 'get',
      description: 'Read the value stored under a key (null if absent).',
      inputSchema: keyProp,
      invoke:
          (args) async => <String, dynamic>{
            'value': await kv.get(requireKey(args)),
          },
    ),
    CapabilityTool(
      verb: 'remove',
      description: 'Delete the value stored under a key.',
      inputSchema: keyProp,
      invoke: (args) async {
        await kv.remove(requireKey(args));
        return <String, dynamic>{'ok': true};
      },
    ),
    CapabilityTool(
      verb: 'exists',
      description: 'Whether a value exists under a key.',
      inputSchema: keyProp,
      invoke:
          (args) async => <String, dynamic>{
            'exists': await kv.exists(requireKey(args)),
          },
    ),
    CapabilityTool(
      verb: 'keys',
      description: 'List keys, optionally filtered by prefix.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'prefix': <String, dynamic>{'type': 'string'},
        },
      },
      invoke:
          (args) async => <String, dynamic>{
            'keys': await kv.keys(prefix: args['prefix'] as String?),
          },
    ),
  ];
}
