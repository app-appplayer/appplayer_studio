import 'dart:io';

import 'package:yaml/yaml.dart';

import '../infra/ws_paths.dart';
import 'skill_definition.dart';
import 'skill_registry.dart';

/// Resolves a Skill definition by id using the 3-layer precedence:
///
///   1. agent overlay : `workspaces/<ws>/members/<agentId>/skills/<id>.yaml`
///   2. workspace     : `workspaces/<ws>/skills/<id>.yaml`
///   3. template      : [AppSkillRegistry] entries (internal + bundle-installed)
///
/// A cached definition is returned; file-system lookups occur on a cache
/// miss. Callers pass the per-call [actorId] to pick up the agent-specific
/// variant if one exists.
class SkillResolver {
  SkillResolver({required this.catalog, required this.workspacesRoot});

  final AppSkillRegistry catalog;
  final String workspacesRoot;

  final Map<String, SkillDefinition> _agentCache = {};
  final Map<String, SkillDefinition> _wsCache = {};

  /// Resolve the effective definition of [skillId] for a given context.
  Future<SkillDefinition?> resolve(
    String skillId, {
    String? workspaceId,
    String? actorId,
  }) async {
    if (workspaceId != null && actorId != null) {
      final agent = await _loadFromFile(
        '${wsContentRoot(workspacesRoot, workspaceId)}/members/$actorId/skills/$skillId.yaml',
        cacheKey: '$workspaceId/$actorId/$skillId',
        cache: _agentCache,
      );
      if (agent != null) return agent;
    }
    if (workspaceId != null) {
      final ws = await _loadFromFile(
        '${wsContentRoot(workspacesRoot, workspaceId)}/skills/$skillId.yaml',
        cacheKey: '$workspaceId/$skillId',
        cache: _wsCache,
      );
      if (ws != null) return ws;
    }
    return catalog.get(skillId);
  }

  /// Enumerate every skill id visible to [workspaceId]+[actorId] combining
  /// the three layers. Agent overlays shadow workspace skills, which in turn
  /// shadow templates.
  Future<Set<String>> visibleIds({String? workspaceId, String? actorId}) async {
    final ids = <String>{for (final s in catalog.list()) s.id};
    if (workspaceId != null) {
      ids.addAll(
        await _listDirIds(
          '${wsContentRoot(workspacesRoot, workspaceId)}/skills',
        ),
      );
    }
    if (workspaceId != null && actorId != null) {
      ids.addAll(
        await _listDirIds(
          '${wsContentRoot(workspacesRoot, workspaceId)}/members/$actorId/skills',
        ),
      );
    }
    return ids;
  }

  /// Drop any cached agent/workspace definition so a subsequent resolve()
  /// rereads from disk. Called after [skill_save] mutations.
  void invalidate({String? workspaceId, String? actorId, String? skillId}) {
    if (skillId == null) {
      _agentCache.clear();
      _wsCache.clear();
      return;
    }
    if (workspaceId != null && actorId != null) {
      _agentCache.remove('$workspaceId/$actorId/$skillId');
    }
    if (workspaceId != null) {
      _wsCache.remove('$workspaceId/$skillId');
    }
  }

  // --- internals ---

  Future<SkillDefinition?> _loadFromFile(
    String path, {
    required String cacheKey,
    required Map<String, SkillDefinition> cache,
  }) async {
    final cached = cache[cacheKey];
    if (cached != null) return cached;
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final yaml = loadYaml(await file.readAsString());
      if (yaml is! YamlMap) return null;
      final def = SkillDefinition.fromYaml(_yamlToMap(yaml));
      cache[cacheKey] = def;
      return def;
    } catch (_) {
      return null;
    }
  }

  Future<Set<String>> _listDirIds(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return const {};
    final out = <String>{};
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!name.endsWith('.yaml') && !name.endsWith('.yml')) continue;
      out.add(name.replaceAll(RegExp(r'\.ya?ml$'), ''));
    }
    return out;
  }

  Map<String, dynamic> _yamlToMap(YamlMap m) {
    final out = <String, dynamic>{};
    m.forEach((k, v) {
      out[k.toString()] =
          v is YamlMap
              ? _yamlToMap(v)
              : v is YamlList
              ? v.map((e) => e is YamlMap ? _yamlToMap(e) : e).toList()
              : v;
    });
    return out;
  }
}
