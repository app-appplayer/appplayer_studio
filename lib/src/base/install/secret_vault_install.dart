/// Host install of the `secret.*` credential vault.
///
/// Pure wiring — the tool list (`secret.set` / `exists` / `remove` / `list`,
/// no plaintext get) comes from the vendored `secure_capability` recipe
/// (`secretCapabilityTools`); this just registers it on the shared host
/// registry over the OS keychain. Production storage = `FlutterSecureStorageBackend`
/// (platform keychain); tests inject an in-memory [SecureStorage].
library;

import 'package:appplayer_secure/appplayer_secure.dart'
    show SecureStorage, FlutterSecureStorageBackend;
import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'capability_recipes/capability_recipes.dart';

/// Register `secret.*` on [registry]. Returns the exposed tool names.
List<String> registerSecretVault(
  mk.HostToolRegistry registry, {
  SecureStorage? store,
}) =>
    registerCapabilityTools(
      registry,
      capabilityId: secretCapabilityId,
      tools: secretCapabilityTools(store ?? FlutterSecureStorageBackend()),
    );
