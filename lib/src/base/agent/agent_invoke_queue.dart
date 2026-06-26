import 'dart:async';

/// Per-agent request serialization — a queue keyed by (already-resolved) agent
/// id. Concurrent invocations of the SAME agent run one at a time: the
/// realistic worker model, where incoming requests queue up and are worked
/// through sequentially rather than all at once.
///
/// It also keeps each agent race-free without a kernel lock: an agent turn is
/// a load → append → write on the conversation store, so two truly-concurrent
/// invocations of one agent could otherwise interleave and drop a turn. By
/// chaining same-agent calls onto one tail, only a single turn is ever in
/// flight per agent. Different agents stay fully parallel (the key is the agent
/// id), so the org keeps time-sharing across its members.
final Map<String, Future<void>> _tails = <String, Future<void>>{};

/// Run [task] after any in-flight call for [agentId] completes, returning its
/// result. Failures propagate to this caller only; the queue continues.
Future<T> serializePerAgent<T>(String agentId, Future<T> Function() task) {
  final prev = _tails[agentId] ?? Future<void>.value();
  final completer = Completer<T>();
  final next = prev.then((_) async {
    try {
      completer.complete(await task());
    } catch (e, st) {
      completer.completeError(e, st);
    }
  });
  _tails[agentId] = next;
  // Drop the tail once it is the last one, so the map doesn't grow unbounded.
  next.whenComplete(() {
    if (identical(_tails[agentId], next)) _tails.remove(agentId);
  });
  return completer.future;
}
