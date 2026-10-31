import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Who a hub session belongs to — the market-signed caller token the relay
/// puts on the session's `open` envelope (`{type:'open', sessionId, caller}`),
/// verified once when the session opens and bound to it for its whole life.
///
/// The market decides who may come in and what they bought; the node only
/// believes the token. A session without a verified caller is not served.
class HubCaller {
  const HubCaller({
    required this.subject,
    required this.token,
    required this.expiresAt,
    this.listingId,
    this.instanceId,
    this.planId,
    this.features = const {},
  });

  /// User uid (`sub`) — the only source of the caller's identity.
  final String subject;

  /// Listing the session was opened for (`lst`). Absent on direct sessions.
  final String? listingId;

  /// Server instance behind this node (`iid`) — the per-user storage cell.
  final String? instanceId;

  /// Plan the caller holds (`plan`). Absent when the listing has no plans or
  /// the session did not come through a purchase.
  final String? planId;

  /// Seller-defined feature values of that plan (`ent`) — opaque to the node.
  final Map<String, Object?> features;

  /// Token expiry, seconds since epoch — the session lives no longer than this.
  final int expiresAt;

  /// The raw token, for a host that forwards it to a server app behind the
  /// node (`Authorization: Bearer`). Never hand it to tools.
  final String token;

  bool isExpiredAt(DateTime now) =>
      now.millisecondsSinceEpoch ~/ 1000 >= expiresAt;
}

/// Verifies a caller token; `null` means the session must not be served.
typedef HubCallerVerifier = Future<HubCaller?> Function(String token);

/// The audience every hub caller token carries — node-specific binding is `nid`.
const hubCallerAudience = 'hub-node';

/// The market's rule for a hub caller token (marketplace DDD 09 §8-4): an
/// EdDSA JWS signed by the market key, `aud == 'hub-node'`, `nid` == this node,
/// not expired. Anything else is refused.
///
/// Holds the public key only — a node cannot mint the tokens it accepts.
/// [publicKeyPem] is the market's SPKI PEM (`MCP_TOKEN_PUBLIC_KEY`).
HubCallerVerifier marketHubCallerVerifier({
  required String publicKeyPem,
  required String nodeId,
  DateTime Function()? now,
}) {
  final key = _ed25519PublicKeyFromPem(publicKeyPem);
  if (key == null) {
    throw ArgumentError.value(
      publicKeyPem,
      'publicKeyPem',
      'not an Ed25519 SPKI public key',
    );
  }
  if (nodeId.isEmpty) {
    throw ArgumentError.value(nodeId, 'nodeId', 'must not be empty');
  }
  final clock = now ?? DateTime.now;
  final publicKey = SimplePublicKey(key, type: KeyPairType.ed25519);
  return (token) async {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final Map<String, dynamic> header;
    final Map<String, dynamic> claims;
    final Uint8List signature;
    try {
      header = _json(parts[0]);
      claims = _json(parts[1]);
      signature = _b64url(parts[2]);
    } catch (_) {
      return null;
    }
    // EdDSA only — a token that downgrades to `none` or HMAC is not the market's.
    if (header['alg'] != 'EdDSA') return null;
    final ok = await Ed25519().verify(
      utf8.encode('${parts[0]}.${parts[1]}'),
      signature: Signature(signature, publicKey: publicKey),
    );
    if (!ok) return null;

    final sub = claims['sub'];
    final exp = claims['exp'];
    if (sub is! String || sub.isEmpty || exp is! int) return null;
    if (claims['aud'] != hubCallerAudience) return null;
    if (claims['nid'] != nodeId) return null;
    final caller = HubCaller(
      subject: sub,
      token: token,
      expiresAt: exp,
      listingId: _str(claims['lst']),
      instanceId: _str(claims['iid']),
      planId: _str(claims['plan']),
      features:
          claims['ent'] is Map
              ? (claims['ent'] as Map).cast<String, Object?>()
              : const {},
    );
    return caller.isExpiredAt(clock()) ? null : caller;
  };
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

Map<String, dynamic> _json(String part) =>
    (jsonDecode(utf8.decode(_b64url(part))) as Map).cast<String, dynamic>();

Uint8List _b64url(String s) => base64Url.decode(base64Url.normalize(s));

/// SPKI PEM → the raw 32-byte Ed25519 key (the last 32 bytes of the DER).
Uint8List? _ed25519PublicKeyFromPem(String pem) {
  final body = pem
      .replaceAll(RegExp(r'-----(BEGIN|END) PUBLIC KEY-----'), '')
      .replaceAll(RegExp(r'\s'), '');
  if (body.isEmpty) return null;
  try {
    final der = base64.decode(body);
    if (der.length < 32) return null;
    return Uint8List.fromList(der.sublist(der.length - 32));
  } catch (_) {
    return null;
  }
}
