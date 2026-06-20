/// In-memory event bus atom — `host.bus.*`. Per-bundle queue of
/// events keyed by channel string. Tools `publish` payloads, other
/// tools (or repeat invocations of the same one) `consume` accumulated
/// payloads. Bus state lives only as long as the activation context.
///
/// Why `consume` (drain queue) instead of `subscribe` (callback)?
/// The bridge protocol is request/response — JS-side callbacks would
/// need a second channel and a registry. The drain pattern stays
/// inside one round-trip per call: JS asks "what's new on `<channel>`",
/// gets back the list since last drain. Subscriptions can be layered
/// on top via JS-side polling.
library;

import 'atom_category.dart';

class BusAtom extends AtomCategory {
  /// Channel name → pending payloads (FIFO, drained on `consume`).
  final Map<String, List<Object?>> _queues = <String, List<Object?>>{};

  @override
  String get key => 'bus';

  @override
  List<AtomVerb> get verbs => const [
    AtomVerb(
      'publish',
      description:
          'Append a payload onto the queue for `<channel>`. '
          'Returns the new queue length.',
    ),
    AtomVerb(
      'consume',
      description:
          'Drain and return all pending payloads on '
          '`<channel>`. Returns an array (empty when nothing was '
          'published).',
    ),
    AtomVerb(
      'channels',
      description: 'List channel names that currently have pending payloads.',
    ),
  ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    switch (verb) {
      case 'publish':
        if (args.length < 2) {
          throw ArgumentError('publish requires (channel, payload)');
        }
        final channel = _channelArg(args[0]);
        final payload = args[1];
        final queue = _queues.putIfAbsent(channel, () => <Object?>[]);
        queue.add(payload);
        return queue.length;
      case 'consume':
        if (args.isEmpty) {
          throw ArgumentError('consume requires (channel)');
        }
        final channel = _channelArg(args[0]);
        final queue = _queues.remove(channel);
        return queue ?? const <Object?>[];
      case 'channels':
        return _queues.keys.toList();
      default:
        throw ArgumentError('unknown verb: bus.$verb');
    }
  }

  String _channelArg(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      throw ArgumentError('channel must be a non-empty String');
    }
    return raw;
  }
}
