/// Builds the board-discovery trust evaluator from Studio's bundled root-CA
/// anchor (`assets/root_cas/dev.json`).
///
/// The evaluator needs an `AppPlayerSecure` for three things only —
/// `validateChain` (trust), `crypto.verifySignature`, and `audit.record`.
/// None of those touch mutual auth, so the facade's local device identity is a
/// placeholder here (Studio never runs mauth from this facade). A production
/// build swaps the bundled `dev.json` for the real partner / marketplace root
/// CAs; the code path is unchanged.
///
/// Returns null on any load/parse failure so discovery degrades to "no trust
/// evidence" rather than blocking boot.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:appplayer_secure/appplayer_secure.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'device_discovery/device_discovery.dart' show BoardIdentity;
import 'discovery_trust.dart';

/// Path to the bundled dev trust anchor. Replace the asset (not the path) for a
/// production trust set.
const String kDiscoveryRootCaAsset = 'assets/root_cas/dev.json';

// In the pro overlay tier the standard package's assets bundle under
// `packages/appplayer_studio/…`, so the unprefixed key throws — same footgun
// as project_seed's `_loadSeedAsset`. Try the bare key, then the prefixed one.
const String _packageAssetPrefix = 'packages/appplayer_studio';

Future<String> _loadAnchorAsset() async {
  try {
    return await rootBundle.loadString(kDiscoveryRootCaAsset);
  } catch (_) {
    return rootBundle.loadString('$_packageAssetPrefix/$kDiscoveryRootCaAsset');
  }
}

/// Load the root-CA anchor and return the discovery trust evaluator, or null if
/// the anchor is missing / malformed (discovery then carries no evidence).
Future<Future<TrustEvidence?> Function(BoardIdentity)?>
    buildDiscoveryTrustEvaluator() async {
  try {
    final raw = await _loadAnchorAsset();
    final spec = (jsonDecode(raw) as Map).cast<String, Object?>();
    final rootCAs = AppPlayerRootCAs.fromJsonSpec(spec);
    if (rootCAs.registeredRoles.isEmpty) return null;
    final secure = AppPlayerSecure.production(
      rootCAs: rootCAs,
      // Placeholder device identity — discovery verification never uses mauth.
      localPrivate: _placeholderKey(isPrivate: true),
      localCert: _placeholderCert(),
    );
    return ManifestTrustEvaluator(secure: secure).evaluate;
  } catch (_) {
    return null;
  }
}

KeyMaterial _placeholderKey({required bool isPrivate}) => KeyMaterial(
      raw: Uint8List(32),
      algorithm: 'ed25519',
      isPrivate: isPrivate,
    );

Certificate _placeholderCert() => Certificate(
      derBytes: Uint8List(32),
      serial: 'studio-local-placeholder',
      publicKey: _placeholderKey(isPrivate: false),
      notBefore: DateTime.utc(2020),
      notAfter: DateTime.utc(2100),
      signatureAlgorithm: 'ed25519',
      fingerprint: '',
    );
