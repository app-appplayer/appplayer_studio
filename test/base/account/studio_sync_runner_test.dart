/// Whether Studio's taste actually moves — each test is one thing a person
/// lives through: the theme set on another device shows up here, the theme
/// set here reaches the account, and AppPlayer's language is not erased by a
/// product that has none.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:appplayer_studio/src/base/account/account_storage.dart';
import 'package:appplayer_studio/src/base/account/in_memory_account_storage.dart';
import 'package:appplayer_studio/src/base/account/studio_cloud_sync.dart';
import 'package:appplayer_studio/src/base/account/studio_sync_runner.dart';
import 'package:appplayer_studio/src/base/account/synced_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// One Studio device: its theme, and a runner joined to [storage].
class _Device {
  _Device(this.storage, {String theme = 'dark', DateTime Function()? now})
    : themeMode = ValueNotifier<String>(theme) {
    runner = StudioSyncRunner(
      sync: StudioCloudSync(storage: storage, deviceId: 'desk'),
      themeMode: themeMode,
      applyThemeMode: (mode) => themeMode.value = mode,
      now: now,
      coalesce: const Duration(milliseconds: 20),
    );
  }

  final AccountStorage storage;
  final ValueNotifier<String> themeMode;
  late final StudioSyncRunner runner;
}

class _Unreachable extends InMemoryAccountStorage {
  @override
  Future<StoredRecord?> get(StorageScope scope, String key) async =>
      throw StateError('account unreachable');

  @override
  Future<WriteReceipt> put(
    StorageScope scope,
    String key,
    Uint8List body, {
    required String contentType,
    String? ifMatch,
  }) async => throw StateError('account unreachable');
}

/// Records the theme of every write to the taste document.
class _RecordingStorage extends InMemoryAccountStorage {
  final List<String> writes = <String>[];

  @override
  Future<WriteReceipt> put(
    StorageScope scope,
    String key,
    Uint8List body, {
    required String contentType,
    String? ifMatch,
  }) async {
    if (scope == StorageScope.common && key == 'settings') {
      final doc = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
      writes.add('${(doc['theme'] as Map?)?['v']}');
    }
    return super.put(
      scope,
      key,
      body,
      contentType: contentType,
      ifMatch: ifMatch,
    );
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 80));

Future<Map<String, Object?>> _common(AccountStorage storage) async {
  final record = await storage.get(StorageScope.common, 'settings');
  return jsonDecode(utf8.decode(record!.body)) as Map<String, Object?>;
}

void main() {
  test('joining with nothing in the account puts this theme there', () async {
    final storage = InMemoryAccountStorage();
    final device = _Device(storage, theme: 'light');
    await device.runner.start();

    final doc = await _common(storage);
    expect((doc['theme'] as Map)['v'], 'light');
    expect(device.runner.status.value.phase, SyncPhase.idle);
    expect(device.runner.status.value.lastSyncAt, isNotNull);
    device.runner.dispose();
  });

  test('a theme set on another device is applied on joining', () async {
    final storage = InMemoryAccountStorage();
    final other = _Device(storage, theme: 'light');
    await other.runner.start();
    other.runner.dispose();

    final here = _Device(storage, theme: 'dark');
    await here.runner.start();
    expect(here.themeMode.value, 'light');
    here.runner.dispose();
  });

  test('a change here is pushed once, coalesced', () async {
    final storage = InMemoryAccountStorage();
    final device = _Device(storage);
    await device.runner.start();
    final before = (await storage.list(StorageScope.common)).single.version;

    device.themeMode.value = 'light';
    device.themeMode.value = 'system';
    await _settle();

    final rows = await storage.list(StorageScope.common);
    expect((await _common(storage))['theme'], containsPair('v', 'system'));
    expect(rows.single.version, isNot(before));
    device.runner.dispose();
  });

  test('another product\'s language travels back unchanged', () async {
    final storage = InMemoryAccountStorage();
    final at = DateTime.utc(2026, 9, 1);
    final appPlayer = settingsDocument(storage);
    await appPlayer.save(
      const SyncedSettings().withTheme('dark', at).copyLocale('ko', at),
    );

    final device = _Device(storage, theme: 'dark');
    await device.runner.start();
    device.themeMode.value = 'light';
    await _settle();

    final doc = await _common(storage);
    expect((doc['theme'] as Map)['v'], 'light');
    expect((doc['locale'] as Map)['v'], 'ko');
    device.runner.dispose();
  });

  test('a theme Studio cannot show is left in the account, not applied', () async {
    final storage = InMemoryAccountStorage();
    await settingsDocument(storage).save(
      const SyncedSettings().withTheme('sepia', DateTime.utc(2026, 9, 1)),
    );
    final device = _Device(storage, theme: 'dark');
    await device.runner.start();
    expect(device.themeMode.value, 'dark');
    device.runner.dispose();
  });

  test('what came down is not pushed back up', () async {
    final storage = InMemoryAccountStorage();
    final other = _Device(storage, theme: 'light');
    await other.runner.start();
    other.runner.dispose();
    final before = (await storage.list(StorageScope.common)).single.version;

    final here = _Device(storage, theme: 'dark');
    await here.runner.start();
    await _settle();

    expect((await storage.list(StorageScope.common)).single.version, before);
    here.runner.dispose();
  });

  test('a theme the host applies on its next frame is not pushed back stale',
      () async {
    // The real host applies a pulled theme through a shell rebuild, so its
    // theme listenable reports the new value only afterwards. Joining must
    // not write the old local theme to the account in between, nor write the
    // arrived one again when the listenable catches up.
    final storage = _RecordingStorage();
    final other = _Device(storage, theme: 'light');
    await other.runner.start();
    other.runner.dispose();
    final before = (await storage.list(StorageScope.common)).single.version;
    storage.writes.clear();

    final themeMode = ValueNotifier<String>('dark');
    final runner = StudioSyncRunner(
      sync: StudioCloudSync(storage: storage, deviceId: 'desk-2'),
      themeMode: themeMode,
      applyThemeMode:
          (mode) => Future<void>.delayed(
            const Duration(milliseconds: 5),
            () => themeMode.value = mode,
          ),
      coalesce: const Duration(milliseconds: 20),
    );
    await runner.start();
    await _settle();

    expect(themeMode.value, 'light');
    expect(storage.writes, isEmpty, reason: 'nothing new was set here');
    expect((await storage.list(StorageScope.common)).single.version, before);

    // A real change here afterwards still goes up.
    themeMode.value = 'system';
    await _settle();
    expect(storage.writes, <String>['system']);
    runner.dispose();
  });

  test('Sync now brings another device\'s change', () async {
    final storage = InMemoryAccountStorage();
    final here = _Device(storage, theme: 'dark');
    await here.runner.start();

    final there = _Device(storage, theme: 'dark');
    await there.runner.start();
    there.themeMode.value = 'light';
    await _settle();
    there.runner.dispose();

    await here.runner.syncNow();
    expect(here.themeMode.value, 'light');
    here.runner.dispose();
  });

  test('an unreachable account is reported as failed, not as synced', () async {
    final device = _Device(_Unreachable());
    await device.runner.start();
    expect(device.runner.status.value.phase, SyncPhase.failed);
    expect(device.runner.status.value.lastSyncAt, isNull);
    expect(device.runner.status.value.lastError, contains('unreachable'));
    device.runner.dispose();
  });

  test('after dispose a change here is not pushed', () async {
    final storage = InMemoryAccountStorage();
    final device = _Device(storage);
    await device.runner.start();
    final before = (await storage.list(StorageScope.common)).single.version;
    device.runner.dispose();

    device.themeMode.value = 'light';
    await _settle();
    expect((await storage.list(StorageScope.common)).single.version, before);
  });
}

extension on SyncedSettings {
  SyncedSettings copyLocale(String locale, DateTime at) => SyncedSettings(
    theme: theme,
    locale: Stamped(locale, at),
    logLevel: logLevel,
  );
}
