import 'dart:async';

/// What set an action going.
///
/// Most actions do not care. `location` does: it answers only to an act — a
/// person tapping, typing, choosing — and never to a lifecycle hook, a timer or
/// a binding evaluation. A document that could ask from `onMount` could ask
/// every time it is opened, and the person would never have done anything to
/// be asked.
///
/// The origin rides the zone a dispatch runs in, so it follows everything that
/// dispatch awaits — an `onSuccess`, a `sequence` step, a `delay` — without
/// every executor passing it along. The runtime marks each place it dispatches
/// on its own initiative; a dispatch nobody marked is a widget answering the
/// person, because widget event handlers run in the zone the gesture arrived
/// in, not the one the widget was built in.
enum DispatchOrigin {
  /// A widget event the person caused.
  act,

  /// `onInit` through `onDestroy`, wherever a definition is mounted.
  lifecycle,

  /// Fired by elapsed time, such as a tool call's `onTimeout`.
  timer,

  /// A reaction to state changing — a watcher.
  binding,

  /// Something the runtime reports without the person acting: channel data
  /// and connection changes, content finishing loading, a widget failing.
  runtime;

  static const Object _zoneKey = #flutterMcpUiDispatchOrigin;

  /// The origin of the dispatch running now; [act] outside any marked zone.
  static DispatchOrigin get current =>
      Zone.current[_zoneKey] as DispatchOrigin? ?? DispatchOrigin.act;

  /// Runs [body] with every dispatch it makes — and every dispatch those
  /// await — reporting [origin].
  static R run<R>(DispatchOrigin origin, R Function() body) =>
      runZoned(body, zoneValues: <Object, Object>{_zoneKey: origin});
}
