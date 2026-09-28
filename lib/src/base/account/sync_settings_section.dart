/// The Settings dialog's account sync rows.
///
/// The switch is this device's participation (platform spec 20 §5) and can
/// be set before signing in. What the rows say follows the account:
///   * signed out — sign in to sync;
///   * signed in, the plan being checked — say so;
///   * signed in without a storage plan (or the plan could not be checked) —
///     nothing is stored or shared, and the plan that would open it is named;
///   * with a plan, switch off — what would sync;
///   * syncing — the last sync time and a "Sync now" button that is locked
///     while a sync runs.
///
/// The switch applies at once, like the account it controls — it is not held
/// until the dialog's Save.
library;

import 'package:flutter/material.dart';

import '../settings/settings_dialog.dart' show SettingsSection;
import '../shell/tokens.dart';
import 'studio_account_sync.dart';
import 'studio_sync_runner.dart';

/// The section a host adds to the Settings dialog when its tier has an
/// account.
SettingsSection accountSyncSettingsSection(StudioAccountSync sync) =>
    SettingsSection(
      label: 'Account sync',
      body: AccountSyncSettingsBody(sync: sync),
    );

class AccountSyncSettingsBody extends StatelessWidget {
  const AccountSyncSettingsBody({super.key, required this.sync});

  final StudioAccountSync sync;

  static const String enabledLabel = 'Sync this device';
  static const String signedOutHint =
      'Sign in to the marketplace to sync your theme and app data with your '
      'account';
  static const String signedInHint =
      'Theme and app data sync with your account';
  static const String syncNowLabel = 'Sync now';
  static const String syncingLabel = 'Syncing…';
  static const String lastSyncedLabel = 'Last synced';
  static const String neverLabel = 'Not synced yet';
  static const String failedLabel = 'Sync failed — retrying on the next change';

  /// The plan's name, or a neutral phrase when the tier named none.
  static String _plan(String? name) =>
      (name == null || name.isEmpty) ? 'a storage plan' : name;

  static String checkingHint(String? name) => 'Checking ${_plan(name)}…';

  static String noPlanHint(String? name) =>
      'Syncing between devices needs ${_plan(name)} — for now, your theme and '
      'app data stay on this device';

  static String unknownPlanHint(String? name) =>
      'Could not check ${_plan(name)} — for now, your theme and app data stay '
      'on this device';

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    TextStyle text(Color color) =>
        TextStyle(fontFamily: VibeTokens.fontSans, fontSize: 12, color: color);
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        sync.syncEnabled,
        sync.plan,
        sync.planName,
        sync.session,
        sync.runner,
      ]),
      builder: (context, _) {
        final runner = sync.runner.value;
        final name = sync.planName.value;
        final hint = switch (sync.plan.value) {
          null => signedOutHint,
          AccountPlan.checking => checkingHint(name),
          AccountPlan.none => noPlanHint(name),
          AccountPlan.unknown => unknownPlanHint(name),
          AccountPlan.active => signedInHint,
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text(enabledLabel, style: text(c.textPrimary))),
                const SizedBox(width: VibeTokens.space2),
                Transform.scale(
                  scale: 0.72,
                  child: Switch(
                    value: sync.syncEnabled.value,
                    onChanged: (v) => sync.setSyncEnabled(v),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: VibeTokens.space2),
            if (runner == null)
              Text(hint, style: text(c.textSecondary))
            else
              ValueListenableBuilder<SyncStatus>(
                valueListenable: runner.status,
                builder:
                    (context, status, _) => Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            statusLabel(status),
                            style: text(c.textSecondary),
                          ),
                        ),
                        TextButton(
                          onPressed:
                              status.phase == SyncPhase.syncing
                                  ? null
                                  : runner.syncNow,
                          child: const Text(syncNowLabel),
                        ),
                      ],
                    ),
              ),
          ],
        );
      },
    );
  }

  static String statusLabel(SyncStatus status) {
    switch (status.phase) {
      case SyncPhase.syncing:
        return syncingLabel;
      case SyncPhase.failed:
        return failedLabel;
      case SyncPhase.idle:
        final at = status.lastSyncAt?.toLocal();
        if (at == null) return neverLabel;
        final hh = at.hour.toString().padLeft(2, '0');
        final mm = at.minute.toString().padLeft(2, '0');
        return '$lastSyncedLabel $hh:$mm';
    }
  }
}
