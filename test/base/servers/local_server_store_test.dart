import 'dart:io';

import 'package:appplayer_secure/appplayer_secure.dart';
import 'package:appplayer_studio/src/base/servers/local_server_store.dart';
import 'package:brain_kernel/brain_kernel.dart' show KernelTransportKind;
import 'package:flutter_test/flutter_test.dart';

/// Locks the local-server persistence contract: endpoint + name + credentialRef
/// round-trip on disk, and the access token lands in the keychain vault under
/// the dedicated namespace — never in the plaintext store (spec 14).
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('local_server_store_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('LocalServerStore', () {
    test('HTTP record round-trips (transport + endpoint + credentialRef)', () {
      LocalServerStore(tmp.path).put(
        const LocalServerRecord(
          id: 'https://a.example.com/mcp',
          transport: KernelTransportKind.streamableHttp,
          endpoint: 'https://a.example.com/mcp',
          name: 'Server A',
          credentialRef: 'https://a.example.com/mcp',
        ),
      );

      // A fresh instance reads the same file — durable across "restart".
      final reopened = LocalServerStore(tmp.path);
      final got = reopened.get('https://a.example.com/mcp');
      expect(got, isNotNull);
      expect(got!.name, 'Server A');
      expect(got.transport, KernelTransportKind.streamableHttp);
      expect(got.endpoint, 'https://a.example.com/mcp');
      expect(got.credentialRef, 'https://a.example.com/mcp');
      expect(reopened.list(), hasLength(1));
    });

    test('stdio record round-trips (command + args, no endpoint)', () {
      final store = LocalServerStore(tmp.path);
      store.put(const LocalServerRecord(
        id: '/usr/local/bin/my-server',
        transport: KernelTransportKind.stdio,
        command: '/usr/local/bin/my-server',
        args: <String>['--port', '9000'],
        name: 'Local stdio',
      ));
      final got = LocalServerStore(tmp.path).get('/usr/local/bin/my-server');
      expect(got!.transport, KernelTransportKind.stdio);
      expect(got.command, '/usr/local/bin/my-server');
      expect(got.args, <String>['--port', '9000']);
      expect(got.endpoint, isNull);
    });

    test('put upserts by id (re-add overwrites, no duplicate)', () {
      final store = LocalServerStore(tmp.path);
      store.put(const LocalServerRecord(
          id: 'https://a/mcp',
          transport: KernelTransportKind.streamableHttp,
          endpoint: 'https://a/mcp',
          name: 'First'));
      store.put(const LocalServerRecord(
          id: 'https://a/mcp',
          transport: KernelTransportKind.streamableHttp,
          endpoint: 'https://a/mcp',
          name: 'Second'));
      expect(store.list(), hasLength(1));
      expect(store.get('https://a/mcp')!.name, 'Second');
    });

    test('remove drops the record and fires onChanged', () {
      final store = LocalServerStore(tmp.path);
      var changes = 0;
      store.onChanged = () => changes++;
      store.put(const LocalServerRecord(
          id: 'https://a/mcp',
          transport: KernelTransportKind.streamableHttp,
          endpoint: 'https://a/mcp',
          name: 'A'));
      expect(changes, 1);
      store.remove('https://a/mcp');
      expect(changes, 2);
      expect(store.list(), isEmpty);
    });

    test('a token-less server records no credentialRef', () {
      final store = LocalServerStore(tmp.path);
      store.put(const LocalServerRecord(
          id: 'https://a/mcp',
          transport: KernelTransportKind.streamableHttp,
          endpoint: 'https://a/mcp',
          name: 'A'));
      expect(store.get('https://a/mcp')!.credentialRef, isNull);
    });
  });

  group('LocalServerCredentialVault', () {
    test('token stored under the local.server namespace, never plaintext store',
        () async {
      final storage = InMemorySecureStorage();
      final vault = LocalServerCredentialVault(storage);
      final ref = LocalServerCredentialVault.refFor('https://a/mcp');

      await vault.write(ref, 'bearer-xyz');

      expect(await vault.read(ref), 'bearer-xyz');
      // Present in the dedicated namespace, absent from the default one.
      expect(
        await storage.read(ref, namespace: LocalServerCredentialVault.namespace),
        'bearer-xyz',
      );
      expect(await storage.read(ref), isNull);
    });

    test('delete removes the token (idempotent)', () async {
      final vault = LocalServerCredentialVault(InMemorySecureStorage());
      final ref = LocalServerCredentialVault.refFor('https://a/mcp');
      await vault.write(ref, 'bearer-xyz');
      await vault.delete(ref);
      expect(await vault.read(ref), isNull);
      await vault.delete(ref); // no throw
    });
  });
}
