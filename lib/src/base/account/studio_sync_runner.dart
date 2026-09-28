/// When Studio's taste moves between the account and this device.
///
/// The documents and merge rules live beside this file; this decides **when
/// to pull and when to push**.
///
/// Rules:
///
/// 1. **Pull once right after joining.** That is when what another device or
///    product did shows up here.
/// 2. **Push on change**, coalesced — browsing themes goes up once.
/// 3. **What the account holds wins on joining**; what only this device had
///    goes up with the push that follows.
/// 4. **What came down is not pushed back up.**
/// 5. **A failure never blocks the screen.** A server being briefly down is
///    not the person's action being void — it is reported in [status].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'studio_cloud_sync.dart';
import 'synced_settings.dart';

enum SyncPhase { idle, syncing, failed }

/// What the settings section shows: whether a sync is running, when the last
/// one completed, and why the last one failed.
class SyncStatus {
  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.lastSyncAt,
    this.lastError,
  });

  final SyncPhase phase;

  /// When a pull or push last completed without a failure. Null until then.
  final DateTime? lastSyncAt;

  final String? lastError;
}

/// Theme values Studio can show. Anything else another product wrote is left
/// in the account and not applied here.
const Set<String> _studioThemes = {'system', 'light', 'dark'};

/// Keeps the account's taste and this Studio in step.
///
/// One per joined session. [dispose] on sign-out or when the switch goes off —
/// left alive, the next person's changes would go up to the previous account.
class StudioSyncRunner {
  StudioSyncRunner({
    required StudioCloudSync sync,
    required ValueListenable<String> themeMode,
    required void Function(String themeMode) applyThemeMode,
    void Function(String op, Object error, StackTrace stack)? onError,
    DateTime Function()? now,
    Duration coalesce = const Duration(milliseconds: 600),
  }) : _sync = sync,
       _themeMode = themeMode,
       _applyThemeMode = applyThemeMode,
       _onError = onError,
       _now = now ?? DateTime.now,
       _coalesce = coalesce;

  final StudioCloudSync _sync;
  final ValueListenable<String> _themeMode;
  final void Function(String themeMode) _applyThemeMode;
  final void Function(String op, Object error, StackTrace stack)? _onError;
  final DateTime Function() _now;
  final Duration _coalesce;

  Timer? _pending;
  bool _applying = false;
  bool _started = false;
  bool _disposed = false;

  /// The state of the most recent pull or push.
  final ValueNotifier<SyncStatus> status = ValueNotifier<SyncStatus>(
    const SyncStatus(),
  );

  bool _cycleFailed = false;
  String? _cycleError;

  /// What was last agreed with the account — the base every push starts
  /// from, so fields this product does not own travel back unchanged.
  SyncedSettings _remote = const SyncedSettings();

  /// A theme applied from the account that [_themeMode] has not reported yet.
  ///
  /// A host may apply a theme on its next frame (a shell rebuild). Until the
  /// listenable catches up this is the local value: read the listenable
  /// instead and the push that follows a pull sends the old theme back up,
  /// and the late report then pushes the arrived one again.
  String? _arriving;

  String get _localTheme => _arriving ?? _themeMode.value;

  Future<void> _cycle(Future<void> Function() body) async {
    if (_disposed) return;
    final previous = status.value;
    status.value = SyncStatus(
      phase: SyncPhase.syncing,
      lastSyncAt: previous.lastSyncAt,
    );
    _cycleFailed = false;
    _cycleError = null;
    await body();
    if (_disposed) return;
    status.value =
        _cycleFailed
            ? SyncStatus(
              phase: SyncPhase.failed,
              lastSyncAt: previous.lastSyncAt,
              lastError: _cycleError,
            )
            : SyncStatus(phase: SyncPhase.idle, lastSyncAt: _now());
  }

  /// Pulls once, then pushes on every theme change.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _themeMode.addListener(_schedule);
    await _cycle(_pull);
  }

  /// Pulls what the account holds and pushes what changed here, now — the
  /// settings section's "Sync now".
  Future<void> syncNow() async {
    if (!_started) return start();
    _pending?.cancel();
    await _cycle(_pull);
  }

  /// Stops pulling and pushing. [status] stays readable — a settings section
  /// may still be listening when the switch goes off.
  void dispose() {
    _disposed = true;
    _pending?.cancel();
    _themeMode.removeListener(_schedule);
  }

  Future<void> _pull() async {
    final settings = await _guard('settings.load', _sync.settings.load);
    if (settings != null) {
      _remote = settings;
      final theme = settings.theme?.value;
      if (theme != null &&
          _studioThemes.contains(theme) &&
          theme != _localTheme) {
        _arriving = theme;
        _applying = true;
        try {
          _applyThemeMode(theme);
        } finally {
          _applying = false;
        }
        if (_themeMode.value == theme) _arriving = null;
      }
    }
    await _push();
  }

  void _schedule() {
    if (_disposed) return;
    final arriving = _arriving;
    if (arriving != null) {
      _arriving = null;
      // The host reporting the theme that came down is not a change here.
      if (_themeMode.value == arriving) return;
    }
    if (_applying) return;
    _pending?.cancel();
    _pending = Timer(_coalesce, () => unawaited(_cycle(_push)));
  }

  Future<void> _push() async {
    final theme = _localTheme;
    if (_remote.theme?.value == theme) return;
    final next = _remote.withTheme(theme, _now());
    final saved = await _guard(
      'settings.save',
      () => _sync.settings.save(next),
    );
    if (saved != null) _remote = saved;
  }

  Future<T?> _guard<T>(String op, Future<T> Function() run) async {
    try {
      return await run();
    } catch (error, stack) {
      _cycleFailed = true;
      _cycleError = '$error';
      _onError?.call(op, error, stack);
      return null;
    }
  }
}
