/// The sync switch is the device's, and the device says what it is
/// (platform spec 20 §5): the profile on joining, taste and bundle `kb`
/// records moving only while the switch is on, and nothing left joined after
/// signing out.
library;

import 'dart:async';
import 'dart:convert';

import 'package:appplayer_studio/src/base/account/account_storage.dart';
import 'package:appplayer_studio/src/base/account/in_memory_account_storage.dart';
import 'package:appplayer_studio/src/base/account/studio_account_sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Map<String, Object?>?> _profile(AccountStorage storage) async {
  final record = await storage.get(StorageScope.device('desk-1'), 'profile');
  if (record == null) return null;
  return jsonDecode(utf8.decode(record.body)) as Map<String, Object?>;
}

void main() {
  late InMemoryAccountStorage storage;
  late ValueNotifier<String> theme;
  late List<bool> persisted;
  late StudioAccountSync sync;

  setUp(() {
    storage = InMemoryAccountStorage();
    theme = ValueNotifier<String>('dark');
    persisted = <bool>[];
    sync = StudioAccountSync(
      deviceId: 'desk-1',
      syncEnabled: false,
      themeMode: theme,
      applyThemeMode: (mode) => theme.value = mode,
      persistSyncEnabled: persisted.add,
      platform: 'macOS',
      coalesce: const Duration(milliseconds: 20),
    );
  });

  tearDown(() => sync.dispose());

  test('a signed-in device declares itself, off by default, and sends nothing',
      () async {
    await sync.bind(storage);

    final profile = await _profile(storage);
    expect(profile?['product'], 'studio');
    expect(profile?['platform'], 'macOS');
    expect(profile?['syncEnabled'], isFalse);
    expect(await storage.list(StorageScope.common), isEmpty);
    expect(sync.runner.value, isNull);
    expect(sync.kbAccount.value, isNull,
        reason: 'bundles keep kb on the device while the switch is off');
  });

  test('turning the switch on sends taste, hands out kb records, and says so',
      () async {
    await sync.bind(storage);
    await sync.setSyncEnabled(true);

    expect(persisted, <bool>[true]);
    expect((await _profile(storage))?['syncEnabled'], isTrue);
    expect(
      (await storage.list(StorageScope.common)).map((e) => e.key),
      contains('settings'),
    );
    expect(sync.runner.value, isNotNull);
    expect(sync.kbAccount.value, isNotNull);
  });

  test('turning the switch off stops sending', () async {
    await sync.bind(storage);
    await sync.setSyncEnabled(true);
    final before = (await storage.list(StorageScope.common)).single.version;

    await sync.setSyncEnabled(false);
    theme.value = 'light';
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect((await storage.list(StorageScope.common)).single.version, before);
    expect((await _profile(storage))?['syncEnabled'], isFalse);
    expect(sync.runner.value, isNull);
    expect(sync.kbAccount.value, isNull);
  });

  test('the switch can be set before signing in and applies on joining',
      () async {
    await sync.setSyncEnabled(true);
    expect(await storage.list(StorageScope.device('desk-1')), isEmpty);

    await sync.bind(storage);
    expect((await _profile(storage))?['syncEnabled'], isTrue);
    expect(sync.kbAccount.value, isNotNull);
  });

  test('signing out parts everything', () async {
    await sync.bind(storage);
    await sync.setSyncEnabled(true);

    await sync.bind(null);
    expect(sync.session.value, isNull);
    expect(sync.runner.value, isNull);
    expect(sync.kbAccount.value, isNull);
    expect(sync.syncEnabled.value, isTrue,
        reason: 'the switch is the device\'s, not the session\'s');
  });

  group('signing in is not having somewhere to store', () {
    test('without a plan: nothing is stored or shared, not even the profile',
        () async {
      await sync.setSyncEnabled(true);
      await sync.bind(
        storage,
        hasStorage: () async => false,
        planName: 'AppPlayer Cloud',
      );

      expect(sync.plan.value, AccountPlan.none);
      expect(sync.planName.value, 'AppPlayer Cloud');
      expect(sync.session.value, isNull);
      expect(sync.runner.value, isNull);
      expect(sync.kbAccount.value, isNull, reason: 'bundle kb stays here');
      expect(await _profile(storage), isNull);
      expect(await storage.list(StorageScope.common), isEmpty);
    });

    test('a plan that cannot be checked is not taken as a plan', () async {
      await sync.setSyncEnabled(true);
      await sync.bind(
        storage,
        hasStorage: () async => throw StateError('offline'),
      );

      expect(sync.plan.value, AccountPlan.unknown);
      expect(sync.session.value, isNull);
      expect(await _profile(storage), isNull);
    });

    test('with a plan: the device declares itself, and syncs once switched on',
        () async {
      await sync.bind(storage, hasStorage: () async => true);

      expect(sync.plan.value, AccountPlan.active);
      expect((await _profile(storage))?['syncEnabled'], isFalse);
      expect(sync.kbAccount.value, isNull);

      await sync.setSyncEnabled(true);
      expect(sync.kbAccount.value, isNotNull);
    });

    test('turning the switch on asks again — a plan taken out since signing '
        'in is seen', () async {
      var active = false;
      var asked = 0;
      await sync.bind(
        storage,
        hasStorage: () async {
          asked++;
          return active;
        },
      );
      expect(sync.plan.value, AccountPlan.none);

      active = true;
      await sync.setSyncEnabled(true);

      expect(asked, 2);
      expect(sync.plan.value, AccountPlan.active);
      expect(sync.kbAccount.value, isNotNull);
      expect((await _profile(storage))?['syncEnabled'], isTrue);
    });

    test('signed out: no plan and the plan is not asked', () async {
      var asked = 0;
      await sync.bind(null, hasStorage: () async {
        asked++;
        return true;
      });
      expect(sync.plan.value, isNull);
      expect(asked, 0);
    });

    test('an answer for an account no longer bound is dropped', () async {
      final slow = Completer<bool>();
      final first = sync.bind(storage, hasStorage: () => slow.future);
      await sync.bind(null);
      slow.complete(true);
      await first;

      expect(sync.plan.value, isNull);
      expect(sync.session.value, isNull);
      expect(await _profile(storage), isNull);
    });
  });

  test('a theme already in the account is applied on joining', () async {
    final other = StudioAccountSync(
      deviceId: 'desk-2',
      syncEnabled: true,
      themeMode: ValueNotifier<String>('light'),
      applyThemeMode: (_) {},
    );
    await other.bind(storage);
    other.dispose();

    await sync.setSyncEnabled(true);
    await sync.bind(storage);
    expect(theme.value, 'light');
  });
}
