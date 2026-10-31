import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';

/// A stand-in market: an Ed25519 key pair that signs hub caller tokens the way
/// the market does (EdDSA JWS), and the node-side verifier built from its
/// public key alone.
class TestMarket {
  TestMarket._(this._keyPair, this.publicKeyPem);

  final SimpleKeyPair _keyPair;
  final String publicKeyPem;

  static Future<TestMarket> create() async {
    final kp = await Ed25519().newKeyPair();
    final pub = await kp.extractPublicKey();
    // SPKI DER for Ed25519 = fixed 12-byte header + the 32-byte key.
    final der = <int>[
      0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
      ...pub.bytes,
    ];
    final pem = '-----BEGIN PUBLIC KEY-----\n${base64.encode(der)}\n'
        '-----END PUBLIC KEY-----';
    return TestMarket._(kp, pem);
  }

  HubCallerVerifier verifier(String nodeId, {DateTime Function()? now}) =>
      marketHubCallerVerifier(
          publicKeyPem: publicKeyPem, nodeId: nodeId, now: now);

  /// A caller token for [nodeId], valid for [ttl] unless [claims] say otherwise.
  Future<String> token({
    required String nodeId,
    String sub = 'alice',
    Duration ttl = const Duration(minutes: 30),
    Map<String, Object?> claims = const {},
    String alg = 'EdDSA',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return sign({
      'iss': 'appplayer-market',
      'sub': sub,
      'aud': hubCallerAudience,
      'nid': nodeId,
      'iat': now,
      'exp': now + ttl.inSeconds,
      ...claims,
    }, alg: alg);
  }

  Future<String> sign(Map<String, Object?> payload, {String alg = 'EdDSA'}) async {
    String part(Object o) =>
        base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
    final input = '${part({'alg': alg, 'typ': 'JWT'})}.${part(payload)}';
    final sig = await Ed25519().sign(utf8.encode(input), keyPair: _keyPair);
    return '$input.${base64Url.encode(sig.bytes).replaceAll('=', '')}';
  }
}

/// Wait until [done] holds — for state that settles after an async verdict.
Future<void> until(bool Function() done,
    {Duration timeout = const Duration(seconds: 2)}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
