// In-memory pub/sub + ring buffer for Ops activity. Defined in
// PRD §FM-OBSERVE-01.
//
// One process-wide singleton owned by the boot path. Riverpod exposes
// it via [activityBusProvider] in `state/providers.dart` so any UI can
// subscribe.

import 'dart:async';
import 'dart:collection';

import 'activity_event.dart';

/// Pub/sub bus with a bounded ring buffer of recent events.
///
/// - `emit(e)` — append + broadcast. Keeps the last [bufferSize] events.
/// - `stream` — broadcast Stream for live consumers (Live Feed, Status Bar).
/// - `recent` — snapshot of the ring buffer (oldest first), used by the
///   Diagnostic Export and on Live Feed first paint before the stream
///   delivers new events.
class ActivityBus {
  ActivityBus({this.bufferSize = 500});

  final int bufferSize;
  final Queue<ActivityEvent> _ring = Queue<ActivityEvent>();
  final StreamController<ActivityEvent> _ctrl =
      StreamController<ActivityEvent>.broadcast(sync: false);

  Stream<ActivityEvent> get stream => _ctrl.stream;

  List<ActivityEvent> get recent => List.unmodifiable(_ring);

  void emit(ActivityEvent e) {
    _ring.addLast(e);
    while (_ring.length > bufferSize) {
      _ring.removeFirst();
    }
    if (!_ctrl.isClosed) _ctrl.add(e);
  }

  /// Convenience emitters keep callers terse.
  void info(
    String actor,
    String headline, {
    ActivityKind kind = ActivityKind.info,
    String? workspaceId,
    Map<String, Object?> meta = const {},
  }) {
    emit(
      ActivityEvent(
        ts: DateTime.now(),
        kind: kind,
        actor: actor,
        headline: headline,
        severity: ActivitySeverity.info,
        workspaceId: workspaceId,
        meta: meta,
      ),
    );
  }

  void warn(
    String actor,
    String headline, {
    ActivityKind kind = ActivityKind.info,
    String? workspaceId,
    Map<String, Object?> meta = const {},
  }) {
    emit(
      ActivityEvent(
        ts: DateTime.now(),
        kind: kind,
        actor: actor,
        headline: headline,
        severity: ActivitySeverity.warn,
        workspaceId: workspaceId,
        meta: meta,
      ),
    );
  }

  void error(
    String actor,
    String headline, {
    ActivityKind kind = ActivityKind.error,
    String? workspaceId,
    Map<String, Object?> meta = const {},
  }) {
    emit(
      ActivityEvent(
        ts: DateTime.now(),
        kind: kind,
        actor: actor,
        headline: headline,
        severity: ActivitySeverity.error,
        workspaceId: workspaceId,
        meta: meta,
      ),
    );
  }

  Future<void> dispose() async {
    await _ctrl.close();
    _ring.clear();
  }
}
