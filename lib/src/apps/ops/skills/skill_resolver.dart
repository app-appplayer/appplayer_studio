import 'dart:io';

import 'package:yaml/yaml.dart';

import '../infra/ws_paths.dart';
import 'skill_definition.dart';
import 'skill_registry.dart';

/// Resolves a Skill definition by id using the layered precedence:
///
///   1. agent overlay : `workspaces/<ws>/members/<agentId>/skills/<id>.yaml`
///   2. workspace     : `workspaces/<ws>/skills/<id>.yaml`
///   3. ancestors     : the same `skills/<id>.yaml` walked up the org
///                      [parentId] chain (nearest parent first)
///   4. template      : [AppSkillRegistry] entries (`originOf == null`, or a
///                      workspace-authored entry whose owner is in scope)
///
/// A workspace-authored catalog entry is only visible when its owner is the
/// active workspace or one of its org ancestors — so a sibling/parent
/// workspace never sees another team's skills. A cached definition is
/// returned; file-system lookups occur on a cache miss. Callers pass the
/// per-call [actorId] to pick up the agent-specific variant if one exists.
class SkillResolver {
  SkillResolver({
    required this.catalog,
    required this.workspacesRoot,
    this.ancestorsOf,
  });

  final AppSkillRegistry catalog;
  final String workspacesRoot;

  /// Resolve the org ancestor chain for a workspace id — nearest parent first,
  /// self excluded. Wired by the host after the WorkspaceRegistry is built;
  /// `null` means "no hierarchy" (own workspace + genuine templates only).
  Future<List<String>> Function(String workspaceId)? ancestorsOf;

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
      // Own workspace, then the org ancestor chain (nearest parent first).
      for (final wsScope in await _scopeChain(workspaceId)) {
        final ws = await _loadFromFile(
          '${wsContentRoot(workspacesRoot, wsScope)}/skills/$skillId.yaml',
          cacheKey: '$wsScope/$skillId',
          cache: _wsCache,
        );
        if (ws != null) return ws;
      }
    }
    // Template layer — but a workspace-authored catalog entry must be in scope.
    final tmpl = catalog.get(skillId);
    if (tmpl == null) return null;
    final origin = catalog.originOf(skillId);
    if (_originInScope(origin, await _scopeSet(workspaceId))) return tmpl;
    return null;
  }

  /// Enumerate every skill id visible to [workspaceId]+[actorId] combining the
  /// layers. Agent overlays shadow workspace skills, which shadow ancestor
  /// skills, which shadow templates. Sibling/out-of-scope workspace skills are
  /// excluded.
  Future<Set<String>> visibleIds({String? workspaceId, String? actorId}) async {
    final scope = await _scopeSet(workspaceId);
    final ids = <String>{
      for (final s in catalog.list())
        if (_originInScope(catalog.originOf(s.id), scope)) s.id,
    };
    if (workspaceId != null) {
      for (final wsScope in await _scopeChain(workspaceId)) {
        ids.addAll(
          await _listDirIds('${wsContentRoot(workspacesRoot, wsScope)}/skills'),
        );
      }
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

  /// `[workspaceId, ...ancestors]` (nearest parent first) — the ordered set of
  /// workspace ids whose `skills/` dirs contribute to [workspaceId]. Empty when
  /// [workspaceId] is null.
  Future<List<String>> _scopeChain(String? workspaceId) async {
    if (workspaceId == null) return const [];
    final chain = <String>[workspaceId];
    final anc = ancestorsOf;
    if (anc != null) {
      for (final a in await anc(workspaceId)) {
        if (!chain.contains(a)) chain.add(a);
      }
    }
    return chain;
  }

  Future<Set<String>> _scopeSet(String? workspaceId) async =>
      (await _scopeChain(workspaceId)).toSet();

  /// A catalog entry is in scope when it is a genuine template (`origin` null)
  /// or its owning workspace is the active one or one of its ancestors.
  bool _originInScope(String? origin, Set<String> scope) =>
      origin == null || scope.contains(origin);

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
