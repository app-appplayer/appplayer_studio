/// Example — `appplayer_secure` as the host `secure.*` capability.
///
/// Shape B: wraps the `AppPlayerSecure` **facade** (never the
/// `utils/secure` primitive — security 2-layer separation). The headline
/// host need is at-rest sealing of secrets (e.g. browser auth profiles),
/// so this example exposes `secure.seal` / `secure.open`. Bytes cross the
/// tool boundary as base64.
///
/// This recipe is **separate from the pure-Dart `capability_tools`** because
/// `appplayer_secure` is Flutter-bound (its production storage is the
/// platform keychain — iOS/macOS Keychain, Android Keystore). The host
/// (a Flutter app: AppPlayer Pro/X/Custom, vibe_studio) constructs
/// `AppPlayerSecure.production(...)` and calls
/// `registerCapabilityTools(registry, capabilityId: 'secure',
/// tools: secureCapabilityTools(secure))`.
///
/// Signature / chain verification (`verifyBundle` / `verifyChain` /
/// `validateChain`) are also on the facade; they take typed manifest /
/// certificate payloads rather than simple JSON, so a host maps them
/// case-by-case — they are intentionally not forced into this reference.
library;

import 'dart:convert';

import 'package:appplayer_secure/appplayer_secure.dart';
import 'capability_tool_pack.dart';

/// Capability id (namespace) — exposed names are `secure.seal`, `secure.open`.
const String secureCapabilityId = 'secure';

/// Build the secure capability's tool list over a configured
/// [AppPlayerSecure] facade (host supplies the platform-keychain-backed
/// instance).
List<CapabilityTool> secureCapabilityTools(AppPlayerSecure secure) {
  String requireString(Map<String, dynamic> args, String field) {
    final v = args[field];
    if (v is! String || v.isEmpty) {
      throw CapabilityToolError(
        code: 'secure.bad_input',
        message: '$field (non-empty base64 string) is required',
      );
    }
    return v;
  }

  return <CapabilityTool>[
    CapabilityTool(
      verb: 'seal',
      description: 'At-rest encrypt (seal) base64 bytes under a context.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'data': <String, dynamic>{
            'type': 'string',
            'description': 'base64 plaintext.',
          },
          'context': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['data'],
      },
      invoke: (args) async {
        final sealed = await secure.sealBytes(
          base64Decode(requireString(args, 'data')),
          context: args['context'] as String? ?? '',
        );
        return <String, dynamic>{'sealed': base64Encode(sealed)};
      },
    ),
    CapabilityTool(
      verb: 'open',
      description: 'At-rest decrypt (open) sealed base64 bytes; the same '
          'context used to seal is required.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'sealed': <String, dynamic>{
            'type': 'string',
            'description': 'base64 sealed bytes.',
          },
          'context': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['sealed'],
      },
      invoke: (args) async {
        try {
          final opened = await secure.openBytes(
            base64Decode(requireString(args, 'sealed')),
            context: args['context'] as String? ?? '',
          );
          return <String, dynamic>{'data': base64Encode(opened)};
        } on CapabilityToolError {
          rethrow;
        } on Object catch (e) {
          // Wrong context / tampered ciphertext → auth failure.
          throw CapabilityToolError(
            code: 'secure.open_failed',
            message: '$e',
          );
        }
      },
    ),
  ];
}
