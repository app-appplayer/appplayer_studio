/// LLM keys are kept in the keychain and never written to settings.json;
/// an older plaintext file is migrated on load.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_secure/appplayer_secure.dart'
    show InMemorySecureStorage;
import 'package:appplayer_studio/base.dart';
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Keychain that counts writes, so a no-change save can be seen to skip it.
class _CountingStorage extends InMemorySecureStorage {
  int writes = 0;

  @override
  Future<void> write(String key, String value, {String namespace = 'default'}) {
    writes++;
    return super.write(key, value, namespace: namespace);
  }
}

/// Keychain that refuses every read (locked / access denied).
class _LockedStorage extends InMemorySecureStorage {
  @override
  Future<String?> read(String key, {String namespace = 'default'}) =>
      throw StateError('keychain locked');
}

void main() {
  late Directory tmp;
  late _CountingStorage keychain;

  String settingsPath(String scope) => p.join(tmp.path, scope, 'settings.json');

  Future<Map<String, dynamic>> fileJson(String path) async =>
      jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('llm_keys_');
    keychain = _CountingStorage();
    LlmKeyStore.storage = keychain;
    LlmKeyStore.resetCache();
  });

  tearDown(() async {
    LlmKeyStore.storage = null;
    LlmKeyStore.resetCache();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('save keeps keys out of the file and in the keychain', () async {
    final path = settingsPath('studio_a');
    await VibeSettings(
      llmApiKey: 'sk-legacy',
      llmModel: 'claude-x',
      llmProviders: <String, String>{'anthropic': 'sk-ant'},
    ).save(path);

    final raw = await File(path).readAsString();
    expect(raw, isNot(contains('sk-legacy')));
    expect(raw, isNot(contains('sk-ant')));
    expect((await fileJson(path))['llmModel'], 'claude-x');

    final stored = await keychain.read(
      'studio_a',
      namespace: LlmKeyStore.namespace,
    );
    expect(stored, contains('sk-ant'));

    LlmKeyStore.resetCache();
    final loaded = await VibeSettings.load(path);
    expect(loaded.llmApiKey, 'sk-legacy');
    expect(loaded.keyFor('anthropic'), 'sk-ant');
  });

  test('a plaintext file is migrated into the keychain on load', () async {
    final path = settingsPath('studio_b');
    await Directory(p.dirname(path)).create(recursive: true);
    await File(path).writeAsString(
      jsonEncode(<String, dynamic>{
        'llmApiKey': 'sk-old',
        'llmProviders': <String, String>{'openai': 'sk-oai'},
        'llmModel': 'gpt-x',
      }),
    );

    final loaded = await VibeSettings.load(path);
    expect(loaded.llmApiKey, 'sk-old');
    expect(loaded.keyFor('openai'), 'sk-oai');

    final after = await fileJson(path);
    expect(after.containsKey('llmApiKey'), isFalse);
    expect(after.containsKey('llmProviders'), isFalse);
    expect(after['llmModel'], 'gpt-x');
    expect(
      await keychain.read('studio_b', namespace: LlmKeyStore.namespace),
      contains('sk-oai'),
    );
  });

  test('the keychain wins over a stale plaintext key', () async {
    final path = settingsPath('studio_c');
    await keychain.write(
      'studio_c',
      jsonEncode(<String, dynamic>{
        'providers': <String, String>{'anthropic': 'sk-new'},
      }),
      namespace: LlmKeyStore.namespace,
    );
    await Directory(p.dirname(path)).create(recursive: true);
    await File(path).writeAsString(
      jsonEncode(<String, dynamic>{
        'llmProviders': <String, String>{
          'anthropic': 'sk-stale',
          'gemini': 'sk-gem',
        },
      }),
    );

    final loaded = await VibeSettings.load(path);
    expect(loaded.keyFor('anthropic'), 'sk-new');
    expect(loaded.keyFor('gemini'), 'sk-gem');
    expect(await File(path).readAsString(), isNot(contains('sk-')));
  });

  test('each host instance keeps its own keys', () async {
    await VibeSettings(llmApiKey: 'sk-debug').save(settingsPath('dbg'));
    await VibeSettings(llmApiKey: 'sk-release').save(settingsPath('rel'));
    LlmKeyStore.resetCache();
    expect(
      (await VibeSettings.load(settingsPath('dbg'))).llmApiKey,
      'sk-debug',
    );
    expect(
      (await VibeSettings.load(settingsPath('rel'))).llmApiKey,
      'sk-release',
    );
  });

  test('saving unchanged keys does not touch the keychain again', () async {
    final path = settingsPath('studio_d');
    await VibeSettings(llmApiKey: 'sk-1').save(path);
    final before = keychain.writes;
    await VibeSettings.mutate(path, (s) => s.bumpRecent('/tmp/project'));
    expect(keychain.writes, before);
    expect((await VibeSettings.load(path)).llmApiKey, 'sk-1');
  });

  test('clearing every key deletes the keychain entry', () async {
    final path = settingsPath('studio_e');
    await VibeSettings(llmApiKey: 'sk-1').save(path);
    await VibeSettings.mutate(path, (s) => s.llmApiKey = null);
    expect(
      await keychain.read('studio_e', namespace: LlmKeyStore.namespace),
      isNull,
    );
  });

  test(
    'a locked keychain does not break loading or lose plaintext keys',
    () async {
      LlmKeyStore.storage = _LockedStorage();
      final path = settingsPath('studio_f');
      await Directory(p.dirname(path)).create(recursive: true);
      await File(path).writeAsString(
        jsonEncode(<String, dynamic>{'llmApiKey': 'sk-keep', 'llmModel': 'm'}),
      );
      final loaded = await VibeSettings.load(path);
      expect(loaded.llmModel, 'm');
      expect((await fileJson(path))['llmApiKey'], 'sk-keep');
    },
  );

  group('Ops config', () {
    OpsConfig cfg(String key) => OpsConfig(
      version: 'v1',
      appName: 'Ops',
      activeWorkspace: '',
      workspacesRoot: './ws',
      llm: LlmSettings(
        defaultProvider: 'claude',
        providers: {'claude': LlmProviderSettings(apiKey: key, model: 'm')},
      ),
      mcp: const McpSettings.defaults(),
      browser: const BrowserSettings.defaults(),
      storage: const StorageSettings.defaults(),
      channel: const ChannelSettings.empty(),
      security: const SecuritySettings.defaults(),
    );

    test('save keeps the provider key out of config.yaml', () async {
      final path = p.join(tmp.path, 'ops_a', 'config.yaml');
      await cfg('sk-ops-1').save(path: path);
      final yaml = await File(path).readAsString();
      expect(yaml, isNot(contains('sk-ops-1')));
      expect(
        await keychain.read('ops:ops_a', namespace: LlmKeyStore.namespace),
        contains('sk-ops-1'),
      );
      LlmKeyStore.resetCache();
      final loaded = await OpsConfig.load(path: path);
      expect(loaded.llm.providers['claude']!.apiKey, 'sk-ops-1');
    });

    test('a plaintext config.yaml key is migrated on load', () async {
      final path = p.join(tmp.path, 'ops_b', 'config.yaml');
      await Directory(p.dirname(path)).create(recursive: true);
      await File(path).writeAsString('''
activeWorkspace: ""
llm:
  defaultProvider: claude
  providers:
    claude:
      apiKey: sk-old-ops
      model: m
''');
      final loaded = await OpsConfig.load(path: path);
      expect(loaded.llm.providers['claude']!.apiKey, 'sk-old-ops');
      expect(await File(path).readAsString(), isNot(contains('sk-old-ops')));
      expect(
        await keychain.read('ops:ops_b', namespace: LlmKeyStore.namespace),
        contains('sk-old-ops'),
      );
    });
  });
}
