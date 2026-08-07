import 'runtime_capabilities.dart';

/// The players currently mounted, addressed by the `id` their document gave
/// them (spec §4.9b).
///
/// A registry rather than a lookup through the widget tree: `media.play` runs
/// from an action handler that has no element to search from, and walking the
/// tree would find a widget without finding the session behind it — the session
/// is what can actually be told to play.
class MediaRegistry {
  final Map<String, MediaSession> _mounted = <String, MediaSession>{};

  /// Ids currently mounted. Diagnostics, and what a "not found" report is
  /// measured against.
  Iterable<String> get mountedIds => List.unmodifiable(_mounted.keys);

  void register(String id, MediaSession session) => _mounted[id] = session;

  /// Removed on dispose. A stale entry would accept `media.play` and drive a
  /// player nobody can see — worse than reporting the id as absent.
  void unregister(String id, MediaSession session) {
    if (identical(_mounted[id], session)) _mounted.remove(id);
  }

  MediaSession? operator [](String id) => _mounted[id];
}
