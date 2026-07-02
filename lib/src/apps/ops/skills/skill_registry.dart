import 'dart:async';

import 'skill_definition.dart';

/// In-memory registry for YAML-defined skills.
///
/// Holds two kinds of entry, distinguished by [originOf]:
///   * genuine app-level templates (`workspaceId == null`) — globally visible
///     to every workspace;
///   * workspace-authored skills (`workspaceId != null`) — visible only within
///     their owning workspace + its org descendants ([SkillResolver] applies
///     the scope filter). They are registered here so the host endpoint can
///     expose them as MCP tools and the UI can list them, but they must never
///     leak into a sibling/parent workspace's `skill_list`.
///
/// Used by [SkillExecutor] and registered on the host endpoint via
/// `McpInbound.registerToolsOn`.
class AppSkillRegistry {
  final Map<String, SkillDefinition> _bySkillId = {};

  /// Owning workspace id per skill id (`null` = genuine app template).
  final Map<String, String?> _originBySkillId = {};

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _notify() => _changes.add(null);

  /// Register [s]. Pass [workspaceId] for a workspace-authored skill so its
  /// visibility can be scoped; omit it for a genuine app-level template.
  void register(SkillDefinition s, {String? workspaceId}) {
    _bySkillId[s.id] = s;
    _originBySkillId[s.id] = workspaceId;
    _notify();
  }

  void remove(String id) {
    _originBySkillId.remove(id);
    if (_bySkillId.remove(id) != null) _notify();
  }

  SkillDefinition? get(String id) => _bySkillId[id];

  /// The workspace that authored [id], or `null` for a genuine app template
  /// (or an unknown id).
  String? originOf(String id) => _originBySkillId[id];

  List<SkillDefinition> list() => _bySkillId.values.toList(growable: false);

  int get length => _bySkillId.length;
}
