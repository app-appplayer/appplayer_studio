/// Reference — passphrase-keyed credential **migration** core over the
/// `secret.*` vault, for moving asset credentials between machines.
///
/// The vault's secrets ([secretCapabilityTools]) live in the OS keychain,
/// whose key cannot leave the device. To migrate them, the operator's
/// **passphrase** seals the `{ref: secret}` map into a portable blob
/// (`appplayer_secure`'s [PassphraseSealer] — PBKDF2 → AEAD, key derived
/// purely from the passphrase), which is reopened on the target machine.
///
/// This is the host-agnostic **core**: read the named refs from the vault →
/// seal; open → write each back. **Deciding which refs to migrate is the
/// host's job** (e.g. collecting `credentialRef`s from `asset` facts) and
/// stays in the host — the migrator takes the refs and does the crypto +
/// vault I/O only.
library;

import 'package:appplayer_secure/appplayer_secure.dart'
    show PassphraseSealer, SecureStorage;

import 'secret_example.dart' show defaultCredentialNamespace;

/// Seals/restores a set of vault credential refs under an operator passphrase.
class CredentialMigrator {
  /// [store] is the keychain-backed vault; [namespace] must match the one the
  /// `secret.*` pack writes under (defaults to [defaultCredentialNamespace]).
  /// Inject [sealer] in tests.
  CredentialMigrator(
    this._store, {
    String namespace = defaultCredentialNamespace,
    PassphraseSealer? sealer,
  })  : _namespace = namespace,
        _sealer = sealer ?? PassphraseSealer();

  final SecureStorage _store;
  final String _namespace;
  final PassphraseSealer _sealer;

  /// Reads each of [refs] from the vault and seals the `{ref: secret}` map
  /// under [passphrase] into a portable blob. Refs with no stored secret are
  /// skipped. Returns the blob (null when none of [refs] held a secret) and
  /// the number of credentials sealed. The secret values never leave sealed.
  Future<({String? blob, int count})> seal(
    Iterable<String> refs,
    String passphrase,
  ) async {
    final creds = <String, String>{};
    for (final ref in refs) {
      if (ref.isEmpty) continue;
      final secret = await _store.read(ref, namespace: _namespace);
      if (secret != null && secret.isNotEmpty) creds[ref] = secret;
    }
    if (creds.isEmpty) return (blob: null, count: 0);
    return (blob: await _sealer.seal(creds, passphrase), count: creds.length);
  }

  /// Opens [sealed] with [passphrase] and writes each credential back into the
  /// vault. Returns the restored refs (sorted; never the secret values).
  ///
  /// Throws [FormatException] on a malformed blob and `SecError`
  /// (`aeadAuthenticationFailed`) on a wrong passphrase or tampering — in which
  /// case nothing is written (the failure surfaces before the write loop).
  Future<List<String>> restore(String sealed, String passphrase) async {
    final creds = await _sealer.open(sealed, passphrase);
    final restored = <String>[];
    for (final entry in creds.entries) {
      await _store.write(entry.key, entry.value, namespace: _namespace);
      restored.add(entry.key);
    }
    restored.sort();
    return restored;
  }
}
