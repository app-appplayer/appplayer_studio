/// Real-crypto coverage of the spec 17 §6 verification path: an Ed25519
/// keypair signs the canonical manifest bytes, the pubkey is registered as the
/// partner root, and the evaluator must accept the genuine block and reject
/// tampering / unknown roles / foreign signers. Mirrors AppPlayer Pro's
/// discovery_trust_test so the two verifiers stay in lockstep with the shared
/// signer (`recipes/device_discovery/tool/sign_manifest.dart`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:appplayer_secure/appplayer_secure.dart';
import 'package:appplayer_studio/src/base/bridge/device_discovery/device_discovery.dart'
    show BoardIdentity;
import 'package:appplayer_studio/src/base/bridge/discovery_trust.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DefaultCryptoProvider crypto;
  late KeyMaterial devicePub;
  late KeyMaterial devicePriv;
  late AppPlayerSecure secure;
  late ManifestTrustEvaluator evaluator;

  Certificate certFor(KeyMaterial pub) => Certificate(
        derBytes: Uint8List.fromList(pub.raw),
        serial: 'dev-partner-2026',
        publicKey: pub,
        notBefore: DateTime.utc(2026),
        notAfter: DateTime.utc(2031),
        signatureAlgorithm: 'ed25519',
        // Must match the evaluator's spec-derived fingerprint so the
        // single-cert chain resolves against this root.
        fingerprint: sha256.convert(pub.raw).toString(),
      );

  Map<String, Object?> certSpec(KeyMaterial pub) => {
        'publicKeyBase64': base64.encode(pub.raw),
        'serial': 'dev-partner-2026',
        'notBefore': '2026-01-01T00:00:00Z',
        'notAfter': '2031-01-01T00:00:00Z',
        'algorithm': 'ed25519',
      };

  Future<Map<String, Object?>> signedManifest({
    String role = 'partner',
    KeyMaterial? signerPub,
    KeyMaterial? signerPriv,
  }) async {
    final manifest = <String, Object?>{
      'id': 'acme.vault01',
      'name': 'Acme Vault',
      'version': '1.2.3',
      'entryPoint': 'ui://app',
    };
    final signature = await crypto.signSignature(
      message: canonicalManifestBytes(manifest),
      privateKey: signerPriv ?? devicePriv,
    );
    manifest['trust'] = {
      'role': role,
      'signerCert': certSpec(signerPub ?? devicePub),
      'signatureBase64': base64.encode(signature),
    };
    return manifest;
  }

  BoardIdentity identityOf(Map<String, Object?>? manifest) => BoardIdentity(
        id: 'acme.vault01',
        name: 'Acme Vault',
        version: '1.2.3',
        manifest: manifest,
      );

  Future<List<AuditEntry>> signatureFailures() async =>
      (await secure.audit.readLocal())
          .where((e) => e.payload['name'] == 'app_signature_failed')
          .toList();

  setUp(() async {
    crypto = DefaultCryptoProvider();
    final device = await crypto.generateEd25519KeyPair();
    devicePub = device.publicKey;
    devicePriv = device.privateKey;
    final local = await crypto.generateEd25519KeyPair();
    secure = await AppPlayerSecure.devDefaults(
      rootCAs: AppPlayerRootCAs.fromMap({
        TrustRole.partner: certFor(devicePub),
      }),
      localPrivate: local.privateKey,
      localCert: certFor(local.publicKey),
    );
    evaluator = ManifestTrustEvaluator(secure: secure);
  });

  test('valid partner block → signatureValid + partnerChainValid', () async {
    final evidence =
        await evaluator.evaluate(identityOf(await signedManifest()));
    expect(evidence, isNotNull);
    expect(evidence!.signatureValid, isTrue);
    expect(evidence.partnerChainValid, isTrue);
    expect(await signatureFailures(), isEmpty);
  });

  test('canonicalization — key order does not affect the verdict', () async {
    final manifest = await signedManifest();
    final reordered = <String, Object?>{
      'version': manifest['version'],
      'trust': manifest['trust'],
      'entryPoint': manifest['entryPoint'],
      'name': manifest['name'],
      'id': manifest['id'],
    };
    final evidence = await evaluator.evaluate(identityOf(reordered));
    expect(evidence!.signatureValid, isTrue);
  });

  test('unsigned manifest → null evidence (no audit)', () async {
    final evidence = await evaluator.evaluate(identityOf({
      'id': 'acme.vault01',
      'name': 'Acme Vault',
      'version': '1.2.3',
    }));
    expect(evidence, isNull);
    expect(await signatureFailures(), isEmpty);
  });

  test('no manifest at all → null evidence', () async {
    final evidence = await evaluator.evaluate(identityOf(null));
    expect(evidence, isNull);
    expect(await signatureFailures(), isEmpty);
  });

  test('tampered manifest → invalid + app_signature_failed audit', () async {
    final manifest = await signedManifest();
    manifest['name'] = 'Evil Vault';
    final evidence = await evaluator.evaluate(identityOf(manifest));
    expect(evidence, isNotNull);
    expect(evidence!.signatureValid, isFalse);
    expect(evidence.partnerChainValid, isFalse);
    expect(await signatureFailures(), isNotEmpty);
  });

  test('foreign signer (chain rejected) → invalid + audit', () async {
    final foreign = await crypto.generateEd25519KeyPair();
    final manifest = await signedManifest(
      signerPub: foreign.publicKey,
      signerPriv: foreign.privateKey,
    );
    final evidence = await evaluator.evaluate(identityOf(manifest));
    expect(evidence!.signatureValid, isFalse);
    expect(await signatureFailures(), isNotEmpty);
  });

  test('unaccepted role → invalid + audit', () async {
    final manifest = await signedManifest(role: 'attacker');
    final evidence = await evaluator.evaluate(identityOf(manifest));
    expect(evidence!.signatureValid, isFalse);
    expect(await signatureFailures(), isNotEmpty);
  });

  test('marketplace role validates against the marketplace root', () async {
    final market = await crypto.generateEd25519KeyPair();
    final marketSecure = await AppPlayerSecure.devDefaults(
      rootCAs: AppPlayerRootCAs.fromMap({
        TrustRole.marketplace: certFor(market.publicKey),
      }),
      localPrivate: devicePriv,
      localCert: certFor(devicePub),
    );
    final marketEvaluator = ManifestTrustEvaluator(secure: marketSecure);
    final manifest = await signedManifest(
      role: 'marketplace',
      signerPub: market.publicKey,
      signerPriv: market.privateKey,
    );
    final evidence = await marketEvaluator.evaluate(identityOf(manifest));
    expect(evidence!.signatureValid, isTrue);
    expect(evidence.partnerChainValid, isFalse,
        reason: 'marketplace evidence must not carry the partner distinction');
  });
}
