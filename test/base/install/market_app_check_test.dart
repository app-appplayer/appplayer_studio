/// App Check for hosts without a native provider: the host's own token first,
/// otherwise one minted by the market and held until near its expiry.
library;

import 'dart:convert';

import 'package:appplayer_studio/src/base/install/market_app_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  final far = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;

  test('a native token is used and nothing is minted', () async {
    var calls = 0;
    final check = marketAppCheck(
      baseUrl: 'https://m.test',
      native: () async => 'NATIVE',
      client: http_testing.MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    expect(await check(), 'NATIVE');
    expect(calls, 0);
  });

  test('without a native token the market mints one, once, with the host key',
      () async {
    final seen = <http.Request>[];
    final check = marketAppCheck(
      baseUrl: 'https://m.test',
      native: () async => throw StateError('no provider'),
      client: http_testing.MockClient((req) async {
        seen.add(req);
        return http.Response(jsonEncode({'token': 'MINTED', 'expiresAt': far}), 200);
      }),
    );
    expect(await check(), 'MINTED');
    expect(await check(), 'MINTED');
    expect(seen, hasLength(1));
    expect(seen.single.url.toString(), 'https://m.test/market/appcheck/token');
    expect(seen.single.headers['X-Market-Host-Key'], 'appplayer');
    expect(seen.single.headers.containsKey('authorization'), isFalse);
  });

  test('a refused mint yields no token, not a crash', () async {
    final check = marketAppCheck(
      baseUrl: 'https://m.test',
      client: http_testing.MockClient((_) async => http.Response('{}', 501)),
    );
    expect(await check(), isNull);
  });
}
