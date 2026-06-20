import 'dart:async';

import 'skill_definition.dart';

/// In-memory registry for YAML-defined skills.
///
/// Internal (app asset) skills are loaded first, then workspace overrides
/// replace entries by `id`. Used by [SkillExecutor] and registered on the
/// host endpoint via `McpInbound.registerToolsOn`.
class AppSkillRegistry {
  final Map<String, SkillDefinition> _bySkillId = {};

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _notify() => _changes.add(null);

  void register(SkillDefinition s) {
    _bySkillId[s.id] = s;
    _notify();
  }

  void remove(String id) {
    if (_bySkillId.remove(id) != null) _notify();
  }

  SkillDefinition? get(String id) => _bySkillId[id];

  List<SkillDefinition> list() => _bySkillId.values.toList(growable: false);

  int get length => _bySkillId.length;
}
