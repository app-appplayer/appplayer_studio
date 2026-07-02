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

  test('rootDir is read fresh — a hot-swap moves the tree', () async {
    // The store reads rootDir() per call, so pointing it at a new dir mid-life
    // makes subsequent reads/writes track the new tree (settings/workspace
    // change) rather than the one captured at construction.
    final a = await Directory.systemTemp.createTemp('sealed_auth_swap_a');
    final b = await Directory.systemTemp.createTemp('sealed_auth_swap_b');
    addTearDown(() async {
      if (await a.exists()) await a.delete(recursive: true);
      if (await b.exists()) await b.delete(recursive: true);
    });
    var live = a.path;
    final swap = SealedAuthProfileStore(
      sealer: AtRestSealer(storage: InMemorySecureStorage()),
      rootDir: () => live,
    );
    final path = await swap.put(sample());
    expect(path, startsWith(a.path));

    live = b.path; // hot-swap the root
    // A fresh store on the new root sees nothing from the old tree.
    final onB = SealedAuthProfileStore(sealer: swap.sealer, rootDir: () => b.path);
    expect(await onB.get('acme', 'alice-acme'), isNull);
    // The same store now writes under the new root.
    final path2 = await swap.put(sample());
    expect(path2, startsWith(b.path));
  });

  test('a live put is served from the hot cache without a fresh disk read',
      () async {
    // put warms the in-memory cache; deleting the .enc under the store's feet
    // must not drop the just-sealed profile from a same-instance get.
    await store.put(sample());
    await File('${root.path}/acme/alice-acme.enc').delete();
    final got = await store.get('acme', 'alice-acme');
    expect(got, isNotNull, reason: 'served from hot cache');
    expect(got!.cookies.single.value, 'super-secret-token');
  });

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
