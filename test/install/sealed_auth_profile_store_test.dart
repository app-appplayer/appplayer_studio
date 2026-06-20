/// Tests for [SealedAuthProfileStore] — the host's `BrowserAuthProfilePort`
/// that seals captured browser auth profiles at rest (S2-apply).
///
/// Exercises the seal/open round-trip, the encrypted-at-rest guarantee,
/// the AAD context binding, and the port contract — all without a live
/// Chromium (the runtime/`setAuth` side is covered by the host dogfood).
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_secure/appplayer_secure.dart'
    show AtRestSealer, InMemorySecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_browser/mcp_browser.dart';
import 'package:appplayer_studio/base.dart';

void main() {
  late Directory root;
  late SealedAuthProfileStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sealed_auth_store_test');
    store = SealedAuthProfileStore(
      sealer: AtRestSealer(storage: InMemorySecureStorage()),
      rootDir: () => root.path,
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  BrowserAuthProfile sample() => BrowserAuthProfile(
    id: 'alice-acme',
    tenantId: 'acme',
    label: 'test',
    cookies: <BrowserCookie>[
      const BrowserCookie(
        name: 'session',
        value: 'super-secret-token',
        domain: 'acme.example',
      ),
    ],
    localStorage: <String, String>{'k': 'v'},
  );

  test('put seals to <root>/<tenant>/<id>.enc and returns its path', () async {
    final path = await store.put(sample());
    expect(path, endsWith('acme/alice-acme.enc'));
    expect(await File(path).exists(), isTrue);
  });

  test(
    'persisted bytes are encrypted (no plaintext credential leaks)',
    () async {
      final path = await store.put(sample());
      final raw = await File(path).readAsBytes();
      final asText = utf8.decode(raw, allowMalformed: true);
      expect(asText.contains('super-secret-token'), isFalse);
      expect(asText.contains('session'), isFalse);
    },
  );

  test('get round-trips the full profile', () async {
    await store.put(sample());
    final got = await store.get('acme', 'alice-acme');
    expect(got, isNotNull);
    expect(got!.id, 'alice-acme');
    expect(got.tenantId, 'acme');
    expect(got.cookies.single.value, 'super-secret-token');
    expect(got.localStorage['k'], 'v');
  });

  test('get returns null for an unknown id', () async {
    await store.put(sample());
    expect(await store.get('acme', 'bob-acme'), isNull);
  });

  test(
    'a profile sealed under one identity cannot be opened as another',
    () async {
      // Rename the .enc onto a different id; the AAD context no longer
      // matches, so the open must fail to null rather than mis-decrypt.
      await store.put(sample());
      final src = File('${root.path}/acme/alice-acme.enc');
      final dst = File('${root.path}/acme/mallory-acme.enc');
      await dst.parent.create(recursive: true);
      await src.copy(dst.path);
      // Fresh store so the hot cache does not mask the on-disk read.
      final fresh = SealedAuthProfileStore(
        sealer: store.sealer,
        rootDir: () => root.path,
      );
      expect(await fresh.get('acme', 'mallory-acme'), isNull);
    },
  );

  test('list returns metadata for the tenant; delete removes it', () async {
    await store.put(sample());
    final metas = await store.list('acme');
    expect(
      metas.map((BrowserAuthProfileMeta m) => m.id),
      contains('alice-acme'),
    );

    await store.delete('acme', 'alice-acme');
    expect(await store.get('acme', 'alice-acme'), isNull);
    expect(await store.list('acme'), isEmpty);
  });

  test(
    'rejects path-traversal identifiers (put throws, get is null)',
    () async {
      final evil = BrowserAuthProfile(
        id: '../../escape',
        tenantId: 'acme',
        cookies: const <BrowserCookie>[],
      );
      expect(() => store.put(evil), throwsArgumentError);
      // A traversal id on read must not escape the root — null, no throw out.
      expect(await store.get('../../etc', 'passwd'), isNull);
      expect(await store.get('acme', 'a/b'), isNull);
    },
  );

  test(
    'a store sharing storage opens what another sealed (key persistence)',
    () async {
      final storage = InMemorySecureStorage();
      final a = SealedAuthProfileStore(
        sealer: AtRestSealer(storage: storage),
        rootDir: () => root.path,
      );
      await a.put(sample());
      final b = SealedAuthProfileStore(
        sealer: AtRestSealer(storage: storage),
        rootDir: () => root.path,
      );
      final got = await b.get('acme', 'alice-acme');
      expect(got, isNotNull);
      expect(got!.cookies.single.value, 'super-secret-token');
    },
  );
}
