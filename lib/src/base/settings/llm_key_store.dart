/// LLM API keys live in the OS keychain, never in `settings.json`.
///
/// One keychain entry per settings scope (the settings file's config
/// directory, e.g. `vibe_studio_debug`) holds that scope's legacy single key
/// and its per-provider keys as JSON. The host installs [storage] at boot;
/// every read is cached in-process so repeated settings loads do not reach
/// the keychain again, and a write that changes nothing is skipped.
library;

import 'dart:convert';

import 'package:appplayer_secure/appplayer_secure.dart' show SecureStorage;
import 'package:collection/collection.dart';

/// The LLM keys of one settings scope.
class LlmKeys {
  const LlmKeys({this.legacy, this.providers = const <String, String>{}});

  /// Single-key shells' key (`VibeSettings.llmApiKey`).
  final String? legacy;

  /// Provider id → key (`VibeSettings.llmProviders`).
  final Map<String, String> providers;

  static const LlmKeys empty = LlmKeys();

  bool get isEmpty =>
      (legacy == null || legacy!.isEmpty) &&
      providers.values.every((v) => v.isEmpty);

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (legacy != null && legacy!.isNotEmpty) 'legacy': legacy,
    if (providers.isNotEmpty) 'providers': providers,
  };

  static LlmKeys fromJson(Object? json) {
    if (json is! Map) return empty;
    final providers = json['providers'];
    return LlmKeys(
      legacy: json['legacy'] as String?,
      providers:
          providers is Map
              ? providers.map((k, v) => MapEntry('$k', '$v'))
              : const <String, String>{},
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LlmKeys &&
      other.legacy == legacy &&
      const MapEquality<String, String>().equals(other.providers, providers);

  @override
  int get hashCode =>
      Object.hash(legacy, const MapEquality<String, String>().hash(providers));
}

class LlmKeyStore {
  LlmKeyStore._();

  static const String namespace = 'studio.llm';

  /// The keychain. Installed by the host before settings are loaded. While
  /// unset (unit tests, tools without a keychain) keys are held for the
  /// life of the process only — they are never written anywhere.
  static SecureStorage? storage;

  static final Map<String, LlmKeys> _cache = <String, LlmKeys>{};

  static Future<LlmKeys> read(String scope) async {
    final hit = _cache[scope];
    if (hit != null) return hit;
    final store = storage;
    final raw =
        store == null ? null : await store.read(scope, namespace: namespace);
    LlmKeys keys;
    try {
      keys = raw == null ? LlmKeys.empty : LlmKeys.fromJson(jsonDecode(raw));
    } on FormatException {
      keys = LlmKeys.empty;
    }
    _cache[scope] = keys;
    return keys;
  }

  static Future<void> write(String scope, LlmKeys keys) async {
    if (_cache[scope] == keys) return;
    final store = storage;
    if (store != null) {
      if (keys.isEmpty) {
        await store.delete(scope, namespace: namespace);
      } else {
        await store.write(
          scope,
          jsonEncode(keys.toJson()),
          namespace: namespace,
        );
      }
    }
    _cache[scope] = keys;
  }

  /// Drop the in-process cache (tests switching [storage]).
  static void resetCache() => _cache.clear();
}
