/// Joins a signed-in account to this Studio, and parts them.
///
/// The host owns one of these. A tier that has an account (Pro, through its
/// marketplace sign-in) calls [bind] with that account's storage on sign-in
/// and with null on sign-out; a tier without one never binds, and everything
/// stays on the device.
///
/// **Signing in is not having somewhere to store.** The tier also says how to
/// ask whether the account has a storage plan ([bind]'s `hasStorage`) and what
/// that plan is called. Studio does not name the plan itself: which plan opens
/// storage is the tier's to decide, and may differ from AppPlayer's. An
/// account without a plan keeps everything on this device — no taste, no
/// bundle `kb`, not even the device profile (platform spec 20 §5). The answer
/// is asked on binding and whenever the switch is turned on, never kept as a
/// verdict; one that cannot be had counts as no plan.
///
/// With a plan, two facts are kept apart:
///   * the device profile is written — the device describes itself, including
///     that it does not sync;
///   * taste and bundle `kb` records move only while [syncEnabled] is true.
///     Off by default: Studio is a native app.
library;

import 'dart:async';

import 'package:brain_kernel/brain_kernel.dart' show KbAccountRecords;
import 'package:flutter/foundation.dart';

import 'account_storage.dart';
import 'kb_account_records.dart';
import 'studio_cloud_sync.dart';
import 'studio_sync_runner.dart';

/// Whether the bound account has somewhere to store. Null when no account is
/// bound.
enum AccountPlan {
  /// The answer has not come back yet.
  checking,

  /// The account has a storage plan — this device may take part.
  active,

  /// No plan — nothing is stored or shared between devices.
  none,

  /// The plan could not be checked. Treated as no plan until it answers.
  unknown,
}

class StudioAccountSync {
  StudioAccountSync({
    required this.deviceId,
    required bool syncEnabled,
    required ValueListenable<String> themeMode,
    required void Function(String themeMode) applyThemeMode,
    void Function(bool enabled)? persistSyncEnabled,
    void Function(String op, Object error, StackTrace stack)? onError,
    DateTime Function()? now,
    String? platform,
    Duration coalesce = const Duration(milliseconds: 600),
  }) : syncEnabled = ValueNotifier<bool>(syncEnabled),
       _themeMode = themeMode,
       _applyThemeMode = applyThemeMode,
       _persistSyncEnabled = persistSyncEnabled,
       _onError = onError,
       _now = now ?? DateTime.now,
       _platform = platform ?? defaultTargetPlatform.name,
       _coalesce = coalesce;

  /// This installation's stable id — the `device/<deviceId>` scope.
  final String deviceId;

  /// This device's participation switch.
  final ValueNotifier<bool> syncEnabled;

  /// Whether the bound account has somewhere to store; null when none is
  /// bound.
  final ValueNotifier<AccountPlan?> plan = ValueNotifier<AccountPlan?>(null);

  /// What the tier calls the plan that opens storage (e.g. "AppPlayer Cloud"),
  /// for the words the settings section shows. Null when the tier named none.
  final ValueNotifier<String?> planName = ValueNotifier<String?>(null);

  /// The joined account — set only while an account with a plan is bound.
  final ValueNotifier<StudioCloudSync?> session =
      ValueNotifier<StudioCloudSync?>(null);

  /// The running sync, or null when not joined or the switch is off.
  final ValueNotifier<StudioSyncRunner?> runner =
      ValueNotifier<StudioSyncRunner?>(null);

  /// The account's `kb` records while this device syncs, null otherwise. A
  /// bundle activated while this is null keeps its `kb` on the device.
  final ValueNotifier<KbAccountRecords?> kbAccount =
      ValueNotifier<KbAccountRecords?>(null);

  final ValueListenable<String> _themeMode;
  final void Function(String themeMode) _applyThemeMode;
  final void Function(bool enabled)? _persistSyncEnabled;
  final void Function(String op, Object error, StackTrace stack)? _onError;
  final DateTime Function() _now;
  final String _platform;
  final Duration _coalesce;

  AccountStorage? _storage;
  Future<bool> Function()? _hasStorage;

  /// Bumped on every bind, so an answer that arrives for an account no longer
  /// bound is dropped.
  int _generation = 0;

  /// Bind [storage]'s account, or part when null.
  ///
  /// [hasStorage] asks whether the account has a storage plan; omitted, the
  /// tier vouches that it does. [planName] is what that plan is called.
  /// Completes once the plan is known and, with a plan, the device profile
  /// is written and — when syncing — the first pull has run.
  Future<void> bind(
    AccountStorage? storage, {
    Future<bool> Function()? hasStorage,
    String? planName,
  }) async {
    _generation++;
    _stopRunner();
    session.value = null;
    _storage = storage;
    _hasStorage = hasStorage;
    this.planName.value = storage == null ? null : planName;
    if (storage == null) {
      plan.value = null;
      return;
    }
    await _checkPlan();
  }

  /// Set this device's participation. Turning it on asks about the plan
  /// again — a plan taken out since signing in is seen then.
  Future<void> setSyncEnabled(bool enabled) async {
    if (syncEnabled.value == enabled) return;
    syncEnabled.value = enabled;
    _persistSyncEnabled?.call(enabled);
    if (_storage == null) return;
    if (plan.value != AccountPlan.active) {
      if (enabled) await _checkPlan();
      return;
    }
    await _declare();
    if (enabled) {
      await _startRunner();
    } else {
      _stopRunner();
    }
  }

  Future<void> _checkPlan() async {
    final storage = _storage;
    if (storage == null) return;
    final generation = _generation;
    plan.value = AccountPlan.checking;
    AccountPlan next;
    final ask = _hasStorage;
    if (ask == null) {
      next = AccountPlan.active;
    } else {
      try {
        next = await ask() ? AccountPlan.active : AccountPlan.none;
      } catch (error, stack) {
        _onError?.call('account.plan', error, stack);
        next = AccountPlan.unknown;
      }
    }
    if (generation != _generation) return;
    plan.value = next;
    if (next != AccountPlan.active) {
      _stopRunner();
      session.value = null;
      return;
    }
    session.value ??= StudioCloudSync(storage: storage, deviceId: deviceId);
    await _declare();
    if (generation != _generation) return;
    if (syncEnabled.value) await _startRunner();
  }

  Future<void> _declare() async {
    final sync = session.value;
    if (sync == null) return;
    final profile = DeviceProfile(
      product: kStudioShellProduct,
      platform: _platform,
      syncEnabled: syncEnabled.value,
      updatedAt: _now(),
    );
    try {
      await sync.profile.load();
      await sync.profile.save(profile);
    } catch (error, stack) {
      _onError?.call('device.profile', error, stack);
    }
  }

  Future<void> _startRunner() async {
    final sync = session.value;
    if (sync == null || runner.value != null) return;
    kbAccount.value = AccountStorageKbRecords(sync.storage);
    final next = StudioSyncRunner(
      sync: sync,
      themeMode: _themeMode,
      applyThemeMode: _applyThemeMode,
      onError: _onError,
      now: _now,
      coalesce: _coalesce,
    );
    runner.value = next;
    await next.start();
  }

  void _stopRunner() {
    kbAccount.value = null;
    final current = runner.value;
    runner.value = null;
    current?.dispose();
  }

  void dispose() {
    _generation++;
    _stopRunner();
    session.value = null;
    syncEnabled.dispose();
    plan.dispose();
    planName.dispose();
    session.dispose();
    runner.dispose();
    kbAccount.dispose();
  }
}
