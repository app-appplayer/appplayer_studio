/// Manifest trust verification for discovered boards
/// (`specs/platform/17-device-discovery.md` §6).
///
/// A probe-confirmed manifest may carry a `trust` block: the board's signer
/// certificate plus an Ed25519 signature over the canonical manifest bytes
/// (the manifest without `trust`, object keys sorted recursively, compact
/// UTF-8 JSON). This evaluator validates the block against the security
/// facade's root CAs and returns a [TrustEvidence] verdict; the discovery
/// wiring then surfaces the evidence and — when signature enforcement is on —
/// gates the connect on it.
///
/// This is Studio's own copy of the same evaluator AppPlayer Pro ships
/// (`appplayer_pro/lib/adapters/discovery_trust.dart`). The recipe owns the
/// PRODUCER (`device_discovery/tool/sign_manifest.dart`); the verifier is a
/// host adapter over `appplayer_secure`, so each host keeps its own
/// (Studio depends on `appplayer_secure`, not `appplayer_launcher`, so the
/// evidence type is local rather than the launcher pipeline's).
///
/// The canonical-bytes algorithm here MUST stay byte-identical to the signer
/// (`recipes/device_discovery/tool/sign_manifest.dart` `canonicalManifestBytes`)
/// or every genuine signature reads as a mismatch.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:appplayer_secure/appplayer_secure.dart';
import 'package:crypto/crypto.dart' show sha256;

import 'device_discovery/device_discovery.dart' show BoardIdentity;

/// The verification verdict for a discovered board's `trust` block.
///
/// [signatureValid] is the gate: a genuine, chain-validated signature over the
/// canonical bytes. [partnerChainValid] additionally marks a `partner`-role
/// signer (marketplace-role evidence is valid but does not carry the partner
/// distinction) — kept for parity with the launcher pipeline's evidence so a
/// future policy can treat the two roles differently.
class TrustEvidence {
  const TrustEvidence({
    required this.partnerChainValid,
    required this.signatureValid,
  });

  final bool partnerChainValid;
  final bool signatureValid;
}

/// Roles a discovered board may claim (spec 17 §6.1). Any other value is
/// untrusted — the evidence comes back invalid.
const Map<String, TrustRole> _acceptedRoles = {
  'partner': TrustRole.partner,
  'marketplace': TrustRole.marketplace,
};

class ManifestTrustEvaluator {
  ManifestTrustEvaluator({required AppPlayerSecure secure}) : _secure = secure;

  final AppPlayerSecure _secure;

  /// Null = the manifest carries no `trust` block (unsigned candidate —
  /// dropped when signature enforcement is on, surfaced otherwise). Non-null
  /// = the block was present and this is its verification verdict. An invalid
  /// signature is always recorded as `app_signature_failed`.
  Future<TrustEvidence?> evaluate(BoardIdentity identity) async {
    final manifest = identity.manifest;
    if (manifest == null) return null;
    final trust = manifest['trust'];
    if (trust is! Map) return null;

    final claimedRole = trust['role'];
    final role = claimedRole is String ? _acceptedRoles[claimedRole] : null;
    if (role == null) {
      return _failed('$claimedRole', 'unaccepted trust role');
    }

    final Certificate signerCert;
    final Uint8List signature;
    try {
      signerCert = _certFromSpec(
        (trust['signerCert'] as Map).cast<String, Object?>(),
      );
      signature = base64.decode(trust['signatureBase64'] as String);
    } catch (e) {
      return _failed(role.roleId, 'malformed trust block: $e');
    }

    final chainOk = await _secure.validateChain([signerCert], role);
    if (!chainOk) {
      return _failed(role.roleId, 'signer chain rejected');
    }

    final message = canonicalManifestBytes(manifest);
    final bool sigOk;
    try {
      sigOk = await _secure.crypto.verifySignature(
        message: message,
        signature: signature,
        publicKey: signerCert.publicKey,
      );
    } catch (e) {
      return _failed(role.roleId, 'signature verify error: $e');
    }
    if (!sigOk) {
      return _failed(role.roleId, 'signature mismatch');
    }

    return TrustEvidence(
      partnerChainValid: role == TrustRole.partner,
      signatureValid: true,
    );
  }

  TrustEvidence _failed(String roleId, String cause) {
    _secure.audit.record(AppSignatureFailed(roleId: roleId, cause: cause));
    return const TrustEvidence(
      partnerChainValid: false,
      signatureValid: false,
    );
  }
}

/// Canonical signing bytes (spec 17 §6.2): the manifest object without its
/// `trust` field, object keys sorted recursively, compact JSON, UTF-8.
Uint8List canonicalManifestBytes(Map<dynamic, dynamic> manifest) {
  final unsigned = Map<String, Object?>.from(manifest.cast<String, Object?>())
    ..remove('trust');
  return Uint8List.fromList(utf8.encode(jsonEncode(_canonicalize(unsigned))));
}

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final sorted = SplayTreeMap<String, Object?>();
    value.cast<String, Object?>().forEach((k, v) {
      sorted[k] = _canonicalize(v);
    });
    return sorted;
  }
  if (value is List) return value.map(_canonicalize).toList();
  return value;
}

/// `trust.signerCert` spec → [Certificate] — the same self-contained shape as
/// the `appplayer_secure` root CA spec entries (raw Ed25519 pubkey in the DER
/// slot · fingerprint = SHA-256(pubkey) hex).
Certificate _certFromSpec(Map<String, Object?> m) {
  final pubBytes = base64.decode(m['publicKeyBase64'] as String);
  if (pubBytes.length != 32) {
    throw FormatException(
      'publicKeyBase64 must decode to 32 bytes — got ${pubBytes.length}',
    );
  }
  return Certificate(
    derBytes: Uint8List.fromList(pubBytes),
    serial: m['serial'] as String,
    publicKey: KeyMaterial(
      raw: Uint8List.fromList(pubBytes),
      algorithm: (m['algorithm'] as String?) ?? 'ed25519',
      isPrivate: false,
    ),
    notBefore: DateTime.parse(m['notBefore'] as String),
    notAfter: DateTime.parse(m['notAfter'] as String),
    signatureAlgorithm: (m['algorithm'] as String?) ?? 'ed25519',
    fingerprint: sha256.convert(pubBytes).toString(),
  );
}
