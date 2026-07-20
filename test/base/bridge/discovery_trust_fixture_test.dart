/// Fixture agreement: the signed manifest the `posix-tcp` dev node ships
/// (`embedded/mcp_node/c_cpp/targets/posix-tcp/main.c` `NODE_TRUST`, signed by
/// the recipe's dev partner key) MUST verify against Studio's evaluator when
/// the dev partner cert is the registered `partner` root. This locks the
/// producer (embedded C fixture) ↔ verifier (this evaluator) ↔ canonical-bytes
/// algorithm together: if the node re-signs, or the canonical algorithm drifts,
/// or the dev root pubkey changes, this test breaks first.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:appplayer_secure/appplayer_secure.dart';
import 'package:appplayer_secure/src/cryptography/default_crypto_provider.dart';
import 'package:appplayer_studio/src/base/bridge/device_discovery/device_discovery.dart'
    show BoardIdentity;
import 'package:appplayer_studio/src/base/bridge/discovery_trust.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';

// The dev partner root — pubkey is `assets/root_cas/dev.json` `partner` and the
// `signerCert` the posix-tcp node serves in its trust block.
const String kDevPartnerPubB64 = 'ncOXHhpEd2Qk/iEXoLtQyyql0OoOxbvvx30slJSjMU4=';

// The exact trust block baked into posix-tcp/main.c `NODE_TRUST`.
const Map<String, Object?> kNodeTrust = {
  'role': 'partner',
  'signerCert': {
    'publicKeyBase64': kDevPartnerPubB64,
    'serial': 'dev-partner-2026',
    'notBefore': '2026-01-01T00:00:00Z',
    'notAfter': '2031-01-01T00:00:00Z',
    'algorithm': 'ed25519',
  },
  'signatureBase64':
      'O26YkzLCKHnd76qvkUu8V8pT76Fqh2eXoPLAl8l74Zdx7t3P+bLpvbMpliQvdXlgSOowJkJbSEwqwYyJmKYaAw==',
};

// The manifest the node serves (led.c serve_manifest) — {id,name,version,
// entryPoint} + trust. Canonical bytes = this minus trust, keys sorted.
const Map<String, Object?> kServedManifest = {
  'id': 'posix.demo',
  'name': 'POSIX TCP MCP Node',
  'version': '0.1.0',
  'entryPoint': 'ui://app',
  'trust': kNodeTrust,
};

void main() {
  test('posix-tcp dev node manifest verifies against the dev partner root',
      () async {
    final pub = base64.decode(kDevPartnerPubB64);
    final partnerCert = Certificate(
      derBytes: Uint8List.fromList(pub),
      serial: 'dev-partner-2026',
      publicKey: KeyMaterial(
        raw: Uint8List.fromList(pub),
        algorithm: 'ed25519',
        isPrivate: false,
      ),
      notBefore: DateTime.utc(2026),
      notAfter: DateTime.utc(2031),
      signatureAlgorithm: 'ed25519',
      fingerprint: sha256.convert(pub).toString(),
    );
    final local = await DefaultCryptoProvider().generateEd25519KeyPair();
    final secure = await AppPlayerSecure.devDefaults(
      rootCAs: AppPlayerRootCAs.fromMap({TrustRole.partner: partnerCert}),
      localPrivate: local.privateKey,
      localCert: partnerCert,
    );
    final evaluator = ManifestTrustEvaluator(secure: secure);

    final evidence = await evaluator.evaluate(const BoardIdentity(
      id: 'posix.demo',
      name: 'POSIX TCP MCP Node',
      version: '0.1.0',
      entryPoint: 'ui://app',
      manifest: kServedManifest,
    ));

    expect(evidence, isNotNull,
        reason: 'node ships a trust block — evidence must be non-null');
    expect(evidence!.signatureValid, isTrue,
        reason: 'the baked signature must verify over the served manifest');
    expect(evidence.partnerChainValid, isTrue);
  });
}
