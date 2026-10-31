/// App Check for the market's `/market/**` doors on hosts without a native
/// attestation provider (desktop). The host's own provider is tried first; when
/// it yields nothing the token is minted by the market for this app (the mint
/// attests the app, not the user, so no login is sent) and held until shortly
/// before it expires.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:http/http.dart' as http;

/// Host key the market reads on the mint door (first-party app identity).
const String kMarketHostKey = 'appplayer';

/// Builds the App Check provider a hub uses against [baseUrl].
///
/// [native] is the host's own provider; a throwing provider counts as none.
Future<String?> Function() marketAppCheck({
  required String baseUrl,
  Future<String?> Function()? native,
  http.Client? client,
}) {
  final http_ = client ?? http.Client();
  String? held;
  int expiresAt = 0;
  Future<String?>? inFlight;

  Future<String?> mint() async {
    try {
      final res = await http_.post(
        Uri.parse('$baseUrl/market/appcheck/token'),
        headers: const <String, String>{
          'content-type': 'application/json',
          'X-Market-Host-Key': kMarketHostKey,
        },
      );
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final token = body['token'] as String?;
      if (token != null) {
        held = token;
        expiresAt = (body['expiresAt'] as num?)?.toInt() ?? 0;
      }
      return token;
    } on Object {
      return null;
    }
  }

  return () async {
    if (native != null) {
      try {
        final t = await native();
        if (t != null && t.isNotEmpty) return t;
      } on Object {
        // Falls through to the market-minted token.
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (held != null && now < expiresAt - 60) return held;
    return inFlight ??= mint().whenComplete(() => inFlight = null);
  };
}

/// Headers that name this app to the market on every `/market/**` call: the
/// first-party host key and the client platform (the market decides per
/// platform what it serves). Sent to the market origin only.
Map<String, String> marketIdentityHeaders() => <String, String>{
  'X-Market-Host-Key': kMarketHostKey,
  'X-Market-Client-Platform': _platformName(),
};

String _platformName() {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.android => 'android',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.windows => 'windows',
    TargetPlatform.linux => 'linux',
    TargetPlatform.fuchsia => 'fuchsia',
  };
}
