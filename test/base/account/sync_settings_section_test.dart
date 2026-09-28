/// The Settings dialog's account sync rows — what the person sees and presses.
///
/// Signed out: the switch and the sign-in hint. Signed in with the switch off:
/// the signed-in hint. Syncing: the last sync time and a "Sync now" button
/// that is locked while a sync runs.
library;

import 'dart:async';

import 'package:appplayer_studio/src/base/account/in_memory_account_storage.dart';
import 'package:appplayer_studio/src/base/account/studio_account_sync.dart';
import 'package:appplayer_studio/src/base/account/studio_sync_runner.dart';
import 'package:appplayer_studio/src/base/account/sync_settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StudioAccountSync sync;
  late ValueNotifier<String> theme;

  setUp(() {
    theme = ValueNotifier<String>('dark');
    sync = StudioAccountSync(
      deviceId: 'desk-1',
      syncEnabled: false,
      themeMode: theme,
      applyThemeMode: (mode) => theme.value = mode,
      platform: 'macOS',
      now: () => DateTime(2026, 9, 15, 9, 5),
    );
  });

  tearDown(() => sync.dispose());

  Widget screen() => MaterialApp(
    home: Scaffold(body: AccountSyncSettingsBody(sync: sync)),
  );

  TextButton syncNowButton(WidgetTester tester) => tester.widget<TextButton>(
    find.ancestor(
      of: find.text(AccountSyncSettingsBody.syncNowLabel),
      matching: find.byType(TextButton),
    ),
  );

  testWidgets('signed out: the switch and the sign-in hint, no Sync now',
      (tester) async {
    await tester.pumpWidget(screen());

    expect(find.text(AccountSyncSettingsBody.enabledLabel), findsOneWidget);
    expect(find.text(AccountSyncSettingsBody.signedOutHint), findsOneWidget);
    expect(find.text(AccountSyncSettingsBody.syncNowLabel), findsNothing);
  });

  testWidgets('signed in, switch off: the signed-in hint, no Sync now',
      (tester) async {
    await tester.runAsync(() => sync.bind(InMemoryAccountStorage()));
    await tester.pumpWidget(screen());

    expect(find.text(AccountSyncSettingsBody.signedInHint), findsOneWidget);
    expect(find.text(AccountSyncSettingsBody.syncNowLabel), findsNothing);
  });

  testWidgets('signed in without a plan: the plan is named and nothing syncs',
      (tester) async {
    await tester.runAsync(
      () => sync.bind(
        InMemoryAccountStorage(),
        hasStorage: () async => false,
        planName: 'AppPlayer Cloud',
      ),
    );
    await tester.pumpWidget(screen());

    expect(
      find.text(AccountSyncSettingsBody.noPlanHint('AppPlayer Cloud')),
      findsOneWidget,
    );
    expect(find.text(AccountSyncSettingsBody.syncNowLabel), findsNothing);
  });

  testWidgets('a plan that could not be checked says so', (tester) async {
    await tester.runAsync(
      () => sync.bind(
        InMemoryAccountStorage(),
        hasStorage: () async => throw StateError('offline'),
        planName: 'AppPlayer Cloud',
      ),
    );
    await tester.pumpWidget(screen());

    expect(
      find.text(AccountSyncSettingsBody.unknownPlanHint('AppPlayer Cloud')),
      findsOneWidget,
    );
  });

  testWidgets('while the plan is being checked the section says so',
      (tester) async {
    final pending = Completer<bool>();
    unawaited(
      sync.bind(
        InMemoryAccountStorage(),
        hasStorage: () => pending.future,
        planName: 'AppPlayer Cloud',
      ),
    );
    await tester.pumpWidget(screen());

    expect(
      find.text(AccountSyncSettingsBody.checkingHint('AppPlayer Cloud')),
      findsOneWidget,
    );
    pending.complete(false);
    await tester.pump();
  });

  testWidgets('the switch sets this device\'s participation at once',
      (tester) async {
    await tester.pumpWidget(screen());

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(sync.syncEnabled.value, isTrue);
  });

  testWidgets('syncing: status follows the runner and Sync now is locked while '
      'it runs', (tester) async {
    await tester.runAsync(() async {
      await sync.bind(InMemoryAccountStorage());
      await sync.setSyncEnabled(true);
    });
    await tester.pumpWidget(screen());

    expect(find.text('${AccountSyncSettingsBody.lastSyncedLabel} 09:05'),
        findsOneWidget);
    expect(syncNowButton(tester).onPressed, isNotNull);

    final runner = sync.runner.value!;
    runner.status.value = const SyncStatus(phase: SyncPhase.syncing);
    await tester.pump();
    expect(find.text(AccountSyncSettingsBody.syncingLabel), findsOneWidget);
    expect(syncNowButton(tester).onPressed, isNull);

    runner.status.value = const SyncStatus(
      phase: SyncPhase.failed,
      lastError: 'down',
    );
    await tester.pump();
    expect(find.text(AccountSyncSettingsBody.failedLabel), findsOneWidget);
  });

  testWidgets('turning the switch off takes the status row away',
      (tester) async {
    await tester.runAsync(() async {
      await sync.bind(InMemoryAccountStorage());
      await sync.setSyncEnabled(true);
    });
    await tester.pumpWidget(screen());
    expect(find.text(AccountSyncSettingsBody.syncNowLabel), findsOneWidget);

    await tester.runAsync(() => sync.setSyncEnabled(false));
    await tester.pump();
    expect(find.text(AccountSyncSettingsBody.syncNowLabel), findsNothing);
    expect(find.text(AccountSyncSettingsBody.signedInHint), findsOneWidget);
  });
}
