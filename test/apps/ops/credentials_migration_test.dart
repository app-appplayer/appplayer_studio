/// Credential migration uses the platform `PassphraseSealer`
/// (ops-asset-management P4). These guard the dependency contract Studio relies
/// on — a passphrase-sealed `{credentialRef: secret}` map that survives a move
/// to another machine (a fresh sealer instance) and rejects a wrong passphrase.
/// The keychain read/write side is exercised by the live Ops dogfood, not here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_secure/appplayer_secure.dart'
    show PassphraseSealer, InMemorySecureStorage;
import 'package:appplayer_studio/src/base/install/capability_recipes/capability_recipes.dart'
    show CredentialMigrator;

void main() {
  const creds = <String, String>{
    'vault:market-db': 'pg-pa55',
    'vault:home-admin': 'hunter2',
  };
  const passphrase = 'correct horse battery staple';

  test('seal → open roundtrip restores the credential map', () async {
    final blob = await PassphraseSealer().seal(creds, passphrase);
    final back = await PassphraseSealer().open(blob, passphrase);
    expect(back, creds);
  });

  test('blob opens on a different sealer instance (machine-portable)', () async {
    // The source machine seals; the target machine has its own sealer and only
    // the passphrase — no keychain key crosses over.
    final source = PassphraseSealer();
    final target = PassphraseSealer();
    final blob = await source.seal(creds, passphrase);
    expect(await target.open(blob, passphrase), creds);
  });

  test('every seal is unique (fresh salt/nonce)', () async {
    final a = await PassphraseSealer().seal(creds, passphrase);
    final b = await PassphraseSealer().seal(creds, passphrase);
    expect(a, isNot(equals(b)));
  });

  test('wrong passphrase fails authentication, never returns plaintext',
      () async {
    final blob = await PassphraseSealer().seal(creds, passphrase);
    await expectLater(
      PassphraseSealer().open(blob, 'wrong passphrase'),
      throwsA(anything),
    );
  });

  test('empty passphrase is rejected on seal', () async {
    await expectLater(
      PassphraseSealer().seal(creds, ''),
      throwsA(anything),
    );
  });

  group('CredentialMigrator (vendored recipe — vault I/O over the store)', () {
    test('seal named refs → restore into a fresh vault', () async {
      final source = InMemorySecureStorage();
      const ns = 'appplayer.credentials';
      await source.write('vault:a', 's-a', namespace: ns);
      await source.write('vault:b', 's-b', namespace: ns);
      // A declared ref with no stored secret is skipped, not failed.
      final sealed = await CredentialMigrator(source).seal(
        const ['vault:a', 'vault:b', 'vault:never-set'],
        passphrase,
      );
      expect(sealed.count, 2);
      expect(sealed.blob, isNotNull);

      final target = InMemorySecureStorage();
      final restored =
          await CredentialMigrator(target).restore(sealed.blob!, passphrase);
      expect(restored, ['vault:a', 'vault:b']);
      expect(await target.read('vault:a', namespace: ns), 's-a');
      expect(await target.read('vault:b', namespace: ns), 's-b');
    });

    test('no stored secrets → null blob, count 0', () async {
      final sealed = await CredentialMigrator(InMemorySecureStorage())
          .seal(const ['vault:x'], passphrase);
      expect(sealed.blob, isNull);
      expect(sealed.count, 0);
    });

    test('wrong passphrase on restore throws and writes nothing', () async {
      final source = InMemorySecureStorage();
      await source.write('vault:a', 's-a', namespace: 'appplayer.credentials');
      final sealed =
          await CredentialMigrator(source).seal(const ['vault:a'], passphrase);
      final target = InMemorySecureStorage();
      await expectLater(
        CredentialMigrator(target).restore(sealed.blob!, 'WRONG'),
        throwsA(anything),
      );
      expect(
        await target.exists('vault:a', namespace: 'appplayer.credentials'),
        isFalse,
      );
    });
  });
}
