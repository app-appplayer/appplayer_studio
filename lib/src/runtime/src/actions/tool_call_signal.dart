import 'dart:async';

/// Tells a tool executor when the runtime stopped waiting for its call.
///
/// The runtime ends a wait on a document's `timeout`, a `cancel`, or the
/// removal of the page that started it (spec 04_Actions §4.15, §4.16). The
/// call itself belongs to the host; this is how the host learns the wait is
/// over, so it can cancel the request on its side — for an MCP client,
/// `RequestOptions(cancel: ToolCallSignal.current)` sends
/// `notifications/cancelled` with the reason.
abstract final class ToolCallSignal {
  /// The runtime stopped waiting because of a `cancel`.
  static const String cancelled = 'cancelled';

  /// The document's `timeout` ran out.
  static const String timeout = 'timeout';

  /// The page that started the call was removed.
  static const String pageRemoved = 'pageRemoved';

  static final Object _key = Object();

  /// Inside a tool executor the runtime called: completes with one of the
  /// reasons above when the runtime stops waiting, and never completes when
  /// the result arrives. Null anywhere else.
  static Future<String>? get current => Zone.current[_key] as Future<String>?;
}

/// Runs [call] with [signal] as its [ToolCallSignal.current].
Future<T> runWithToolCallSignal<T>(
        Future<String> signal, Future<T> Function() call) =>
    runZoned(call, zoneValues: <Object, Object>{ToolCallSignal._key: signal});
