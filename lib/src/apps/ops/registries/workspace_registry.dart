import 'dart:async';
import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart';
import 'package:yaml/yaml.dart';

import '../util/atomic_write.dart';

/// A directed, scoped, read-only knowledge-share grant from a workspace to
/// another. The owner workspace declares `shares: [{to, scope}]`; the target
/// then reads the owner's facts under `scope` (a fact category, or `*` for
/// all) on top of its own — a **formal** exchange, not the within-workspace
/// "everything is shared" default. This keeps each workspace a sandbox and
/// makes cross-team data flow an explicit contract (`FR-OPS-014`).
class ShareGrant {
  ShareGrant({required this.toWorkspaceId, this.scope = '*'});

  final String toWorkspaceId;

  /// Fact category exposed to [toWorkspaceId]. `'*'` shares every category.
  final String scope;

  Map<String, dynamic> toMap() => {'to': toWorkspaceId, 'scope': scope};

  static ShareGrant fromMap(Map m) => ShareGrant(
    toWorkspaceId: (m['to'] ?? '').toString(),
    scope: (m['scope'] as String?) ?? '*',
  );
}

/// See `SRS §2.10 FR-OPS-014` for the design specification.
class Workspace {
  Workspace({
    required this.id,
    required this.type,
    required this.title,
    required this.locale,
    required this.timezone,
    required this.createdAt,
    this.members = const [],
    this.sharedWith = const [],
    this.shares = const [],
    this.parentId,
    this.tags = const {},
  });

  final String id;
  final WorkspaceType type;
  final String title;
  final String locale;
  final String timezone;
  final DateTime createdAt;
  final List<String> members;

  /// Legacy coarse edge (whole-workspace share, no scope). Kept for
  /// back-compat; scoped grants live in [shares].
  final List<String> sharedWith;

  /// Directed, scoped, read-only knowledge grants this workspace exposes.
  final List<ShareGrant> shares;

  /// Organization hierarchy: the parent workspace this one reports to
  /// (`null` = top of its tree). Builds the org axis of the matrix — e.g.
  /// `개발본부` ← `프론트팀` ← a member's workspace. The ancestor chain is
  /// the approval escalation path (G2/G3). Distinct from the workspace
  /// type/slug (a flat id) — hierarchy is overlay metadata, not nesting.
  final String? parentId;
  final Map<String, String> tags;

  Map<String, dynamic> toYamlMap() => {
    'id': id,
    'type': type.name,
    'title': title,
    'locale': locale,
    'timezone': timezone,
    'createdAt': createdAt.toIso8601String(),
    'members': members.map((m) => {'id': m}).toList(),
    'sharedWith': sharedWith,
    'shares': shares.map((s) => s.toMap()).toList(),
    if (parentId != null) 'parentId': parentId,
    'tags': tags,
  };

  factory Workspace.fromYaml(Map<String, dynamic> y) {
    final members = <String>[];
    final rawMembers = y['members'];
    if (rawMembers is List) {
      for (final m in rawMembers) {
        if (m is Map && m['id'] is String) {
          members.add(m['id'] as String);
        } else if (m is String) {
          members.add(m);
        }
      }
    }
    return Workspace(
      id: y['id'] as String,
      type: WorkspaceType.values.firstWhere(
        (t) => t.name == (y['type'] as String? ?? 'project'),
        orElse: () => WorkspaceType.project,
      ),
      title: (y['title'] as String?) ?? y['id'] as String,
      locale: (y['locale'] as String?) ?? 'ko',
      timezone: (y['timezone'] as String?) ?? 'Asia/Seoul',
      createdAt:
          DateTime.tryParse(y['createdAt'] as String? ?? '') ?? DateTime.now(),
      members: members,
      sharedWith: (y['sharedWith'] as List?)?.cast<String>() ?? const [],
      shares: [
        for (final s in (y['shares'] as List? ?? const []))
          if (s is Map) ShareGrant.fromMap(s),
      ],
      parentId: (y['parentId'] as String?),
      tags:
          (y['tags'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          const {},
    );
  }
}

enum WorkspaceType { org, personal, project }

class WorkspaceRegistry {
  WorkspaceRegistry({required this.kv, required this.rootDir});

  /// Reserved workspace id used by the system administrator agent
  /// (`_ops_admin` lives here). Hidden from [list] by default. Boot path
  /// calls [ensureSystemWorkspace] before the system agent is created.
  static const String systemWorkspaceId = '_system';

  final KvStoragePortAdapter kv;
  final String rootDir;

  final Map<String, Workspace> _cache = {};
  String? _activeId;
  bool _loaded = false;

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _notify() => _changes.add(null);

  String? get activeId => _activeId;

  Future<void> setActive(String id) async {
    _activeId = id;
    kv.workspaceId = id;
    _notify();
  }

  /// Workspace list. Reserved ids (starting with `_`, e.g. `_system`) are
  /// excluded by default — set [includeReserved] true for boot diagnostics
  /// or admin tooling.
  Future<List<Workspace>> list({bool includeReserved = false}) async {
    await _ensureLoaded();
    final copy =
        _cache.values
            .where((w) => includeReserved || !w.id.startsWith('_'))
            .toList();
    copy.sort((a, b) => a.id.compareTo(b.id));
    return copy;
  }

  Future<Workspace?> get(String id) async {
    await _ensureLoaded();
    return _cache[id];
  }

  /// Idempotently ensure the reserved `_system` workspace exists. The
  /// system administrator agent (`_ops_admin`, `cfg.systemAgent.workspaceId`)
  /// lives here. Called by [KnowledgeInit.boot] before the agent is created.
  Future<Workspace> ensureSystemWorkspace() async {
    await _ensureLoaded();
    final existing = _cache[systemWorkspaceId];
    if (existing != null) return existing;
    final dir = Directory('$rootDir/$systemWorkspaceId');
    await dir.create(recursive: true);
    // Content sub-dirs (members / tasks / processes / knowledge / skills /
    // profiles / philosophies / auth) are no longer pre-created here. Per
    // the mcp_bundle project layout (MOD-APPS-007) each workspace's content
    // lives inside its `<wsId>.mbd` bundle dir (see `wsContentRoot`); the
    // content registries create their own sub-dirs on first write and all
    // readers skip-if-missing.
    final ws = Workspace(
      id: systemWorkspaceId,
      // Reserved workspaces use `project` as a placeholder — the id itself
      // is the discriminator. Type does not surface in UI for these.
      type: WorkspaceType.project,
      title: 'System',
      locale: 'en',
      timezone: 'UTC',
      createdAt: DateTime.now(),
      tags: const {'ops:reserved': 'system'},
    );
    await _writeYaml('${dir.path}/config.yaml', ws.toYamlMap());
    _cache[systemWorkspaceId] = ws;
    _notify();
    return ws;
  }

  /// Create an **empty** workspace. Bundle installs are performed separately
  /// via [BundleInstaller.install] so multiple bundles can be layered in.
  Future<Workspace> create({
    required WorkspaceType type,
    required String slug,
    required String title,
    String locale = 'ko',
    String timezone = 'Asia/Seoul',
    Map<String, String> tags = const {},
  }) async {
    await _ensureLoaded();
    if (rootDir.isEmpty) {
      throw StateError(
        'WorkspaceRegistry: workspacesRoot not bound — open an Ops project '
        'before creating workspaces.',
      );
    }
    final id = '${type.name}/$slug';
    if (_cache.containsKey(id)) {
      throw StateError('workspace id already exists: $id');
    }
    final dir = Directory('$rootDir/$id');
    await dir.create(recursive: true);
    // Content sub-dirs (members / tasks / processes / knowledge / skills /
    // profiles / philosophies / auth) are no longer pre-created here. Per
    // the mcp_bundle project layout (MOD-APPS-007) each workspace's content
    // lives inside its `<wsId>.mbd` bundle dir (see `wsContentRoot`); the
    // content registries create their own sub-dirs on first write and all
    // readers skip-if-missing.
    final ws = Workspace(
      id: id,
      type: type,
      title: title,
      locale: locale,
      timezone: timezone,
      createdAt: DateTime.now(),
      tags: tags,
    );
    await _writeYaml('${dir.path}/config.yaml', ws.toYamlMap());
    _cache[id] = ws;
    _notify();
    return ws;
  }

  Future<void> delete(String id) async {
    await _ensureLoaded();
    final dir = Directory('$rootDir/$id');
    if (await dir.exists()) await dir.delete(recursive: true);
    // Clear the workspace's KV keys. Disable scope enforcement for the bulk
    // delete (we are removing another workspace's keys, not the active one).
    final prevWs = kv.workspaceId;
    kv.workspaceId = null;
    for (final k in await kv.keys(prefix: 'ws/$id/')) {
      await kv.remove(k);
    }
    kv.workspaceId = prevWs;
    _cache.remove(id);
    if (_activeId == id) _activeId = null;
    _notify();
  }

  /// Rename a workspace id (`<type>/<oldSlug>` → `<type>/<newSlug>`).
  /// Moves the directory, rewrites its `config.yaml`, migrates the KV
  /// workspace partition (ws/<old>/... → ws/<new>/...) and updates the
  /// active-id cache if the current workspace was renamed.
  Future<Workspace> rename(
    String oldId,
    String newId, {
    String? newTitle,
  }) async {
    await _ensureLoaded();
    final existing = _cache[oldId];
    if (existing == null) throw StateError('workspace not found: $oldId');
    if (_cache.containsKey(newId)) {
      throw StateError('workspace id already exists: $newId');
    }
    final oldDir = Directory('$rootDir/$oldId');
    final newDir = Directory('$rootDir/$newId');
    if (!await oldDir.exists()) {
      throw StateError('workspace directory missing: ${oldDir.path}');
    }
    if (await newDir.exists()) {
      throw StateError('target directory already exists: ${newDir.path}');
    }
    await newDir.parent.create(recursive: true);
    await oldDir.rename(newDir.path);

    final updated = Workspace(
      id: newId,
      type: existing.type,
      title: newTitle ?? existing.title,
      locale: existing.locale,
      timezone: existing.timezone,
      createdAt: existing.createdAt,
      members: existing.members,
      sharedWith: existing.sharedWith,
      shares: existing.shares,
      parentId: existing.parentId,
      tags: existing.tags,
    );
    await _writeYaml('${newDir.path}/config.yaml', updated.toYamlMap());
    _cache.remove(oldId);
    _cache[newId] = updated;

    // KV partition migration — best effort; keys are `ws/<id>/...`.
    final keys = await kv.keys(prefix: 'ws/$oldId/');
    for (final k in keys) {
      final v = await kv.get(k);
      if (v == null) continue;
      final newKey = 'ws/$newId/${k.substring('ws/$oldId/'.length)}';
      // Temporarily widen scope so we can write the new-ws key too.
      final prev = kv.workspaceId!;
      kv.workspaceId = newId;
      await kv.set(newKey, v);
      kv.workspaceId = prev;
    }
    if (_activeId == oldId) {
      _activeId = newId;
      kv.workspaceId = newId;
    }
    _notify();
    return updated;
  }

  /// Update mutable fields (title · locale · timezone · tags).
  Future<Workspace> update(
    String id, {
    String? title,
    String? locale,
    String? timezone,
    Map<String, String>? tags,
  }) async {
    await _ensureLoaded();
    final cur = _cache[id];
    if (cur == null) throw StateError('workspace not found: $id');
    final updated = Workspace(
      id: cur.id,
      type: cur.type,
      title: title ?? cur.title,
      locale: locale ?? cur.locale,
      timezone: timezone ?? cur.timezone,
      createdAt: cur.createdAt,
      members: cur.members,
      sharedWith: cur.sharedWith,
      shares: cur.shares,
      parentId: cur.parentId,
      tags: tags ?? cur.tags,
    );
    await _writeYaml('$rootDir/$id/config.yaml', updated.toYamlMap());
    _cache[id] = updated;
    _notify();
    return updated;
  }

  Future<void> share(String fromId, String toId) async {
    final ws = await get(fromId);
    if (ws == null) throw StateError('workspace not found: $fromId');
    if (ws.sharedWith.contains(toId)) return;
    final updated = Workspace(
      id: ws.id,
      type: ws.type,
      title: ws.title,
      locale: ws.locale,
      timezone: ws.timezone,
      createdAt: ws.createdAt,
      members: ws.members,
      sharedWith: [...ws.sharedWith, toId],
      shares: ws.shares,
      parentId: ws.parentId,
      tags: ws.tags,
    );
    await _writeYaml('$rootDir/${updated.id}/config.yaml', updated.toYamlMap());
    _cache[updated.id] = updated;
    _notify();
  }

  /// Grant [toWorkspaceId] read-only access to this [ownerId] workspace's
  /// facts under [scope] (a fact category, or `'*'` for all). Upserts by
  /// `(to, scope)` so re-granting is idempotent. The target sees these on
  /// top of its own facts via `knowledge_fact_query`; the owner's other
  /// categories stay private (sandbox + formal exchange).
  Future<Workspace> grantShare(
    String ownerId,
    String toWorkspaceId, {
    String scope = '*',
  }) async {
    final ws = await get(ownerId);
    if (ws == null) throw StateError('workspace not found: $ownerId');
    final exists = ws.shares.any(
      (g) => g.toWorkspaceId == toWorkspaceId && g.scope == scope,
    );
    final shares =
        exists
            ? ws.shares
            : [
              ...ws.shares,
              ShareGrant(toWorkspaceId: toWorkspaceId, scope: scope),
            ];
    final updated = _copyWith(ws, shares: shares);
    await _writeYaml('$rootDir/${updated.id}/config.yaml', updated.toYamlMap());
    _cache[updated.id] = updated;
    _notify();
    return updated;
  }

  /// Revoke a previously granted scope (or all grants to [toWorkspaceId]
  /// when [scope] is null).
  Future<Workspace> revokeShare(
    String ownerId,
    String toWorkspaceId, {
    String? scope,
  }) async {
    final ws = await get(ownerId);
    if (ws == null) throw StateError('workspace not found: $ownerId');
    final shares =
        ws.shares
            .where(
              (g) =>
                  g.toWorkspaceId != toWorkspaceId ||
                  (scope != null && g.scope != scope),
            )
            .toList();
    final updated = _copyWith(ws, shares: shares);
    await _writeYaml('$rootDir/${updated.id}/config.yaml', updated.toYamlMap());
    _cache[updated.id] = updated;
    _notify();
    return updated;
  }

  /// Workspaces (besides [targetWsId] itself) that have granted [targetWsId]
  /// a read-only scope — i.e. the incoming shares the target may read.
  Future<List<({String fromWorkspaceId, String scope})>> incomingShares(
    String targetWsId,
  ) async {
    await _ensureLoaded();
    final out = <({String fromWorkspaceId, String scope})>[];
    for (final ws in _cache.values) {
      if (ws.id == targetWsId) continue;
      for (final g in ws.shares) {
        if (g.toWorkspaceId == targetWsId) {
          out.add((fromWorkspaceId: ws.id, scope: g.scope));
        }
      }
    }
    return out;
  }

  /// Set (or clear, when [parentId] is null/empty) this workspace's
  /// organization parent. Rejects a parent that doesn't exist or would
  /// introduce a cycle (a workspace cannot report to its own descendant).
  Future<Workspace> setParent(String id, String? parentId) async {
    await _ensureLoaded();
    final ws = _cache[id];
    if (ws == null) throw StateError('workspace not found: $id');
    final parent = (parentId == null || parentId.isEmpty) ? null : parentId;
    if (parent != null) {
      if (parent == id)
        throw StateError('a workspace cannot be its own parent');
      if (_cache[parent] == null) {
        throw StateError('parent workspace not found: $parent');
      }
      // Cycle guard — walk up from the proposed parent; hitting [id] means
      // [id] is already an ancestor of [parent].
      var cursor = _cache[parent];
      while (cursor != null) {
        if (cursor.id == id) {
          throw StateError('cycle: $parent is a descendant of $id');
        }
        cursor = cursor.parentId == null ? null : _cache[cursor.parentId];
      }
    }
    final updated = _copyWith(
      ws,
      parentId: parent,
      clearParent: parent == null,
    );
    await _writeYaml('$rootDir/${updated.id}/config.yaml', updated.toYamlMap());
    _cache[updated.id] = updated;
    _notify();
    return updated;
  }

  /// Ancestor chain (nearest parent first) — the organization escalation
  /// path. `개발본부 ← 프론트팀 ← ws` returns `[프론트팀, 개발본부]` for `ws`.
  Future<List<String>> ancestors(String id) async {
    await _ensureLoaded();
    final out = <String>[];
    final seen = <String>{id};
    var cur = _cache[id]?.parentId;
    while (cur != null && cur.isNotEmpty && seen.add(cur)) {
      out.add(cur);
      cur = _cache[cur]?.parentId;
    }
    return out;
  }

  /// Direct child workspaces (those whose `parentId` is [id]).
  Future<List<String>> children(String id) async {
    await _ensureLoaded();
    return [
      for (final ws in _cache.values)
        if (ws.parentId == id) ws.id,
    ]..sort();
  }

  Workspace _copyWith(
    Workspace ws, {
    List<ShareGrant>? shares,
    String? parentId,
    bool clearParent = false,
  }) => Workspace(
    id: ws.id,
    type: ws.type,
    title: ws.title,
    locale: ws.locale,
    timezone: ws.timezone,
    createdAt: ws.createdAt,
    members: ws.members,
    sharedWith: ws.sharedWith,
    shares: shares ?? ws.shares,
    parentId: clearParent ? null : (parentId ?? ws.parentId),
    tags: ws.tags,
  );

  // --- internals ---

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final root = Directory(rootDir);
    if (!await root.exists()) {
      _loaded = true;
      return;
    }
    for (final type in WorkspaceType.values) {
      final typeDir = Directory('$rootDir/${type.name}');
      if (!await typeDir.exists()) continue;
      await for (final entry in typeDir.list()) {
        if (entry is! Directory) continue;
        final cfg = File('${entry.path}/config.yaml');
        if (!await cfg.exists()) continue;
        try {
          final raw = await cfg.readAsString();
          final yaml = loadYaml(raw);
          if (yaml is YamlMap) {
            final ws = Workspace.fromYaml(
              _toStringMap(Map<String, dynamic>.from(yaml)),
            );
            _cache[ws.id] = ws;
          }
        } catch (e) {
          stderr.writeln('Workspace load failed: ${cfg.path}: $e');
        }
      }
    }
    // Reserved root-level workspaces (`_system`, …) live outside the
    // type directories. Scan them too so [get] resolves them after restart.
    final reserved = Directory('$rootDir/$systemWorkspaceId');
    if (await reserved.exists()) {
      final cfg = File('${reserved.path}/config.yaml');
      if (await cfg.exists()) {
        try {
          final raw = await cfg.readAsString();
          final yaml = loadYaml(raw);
          if (yaml is YamlMap) {
            final ws = Workspace.fromYaml(
              _toStringMap(Map<String, dynamic>.from(yaml)),
            );
            _cache[ws.id] = ws;
          }
        } catch (e) {
          stderr.writeln('System workspace load failed: ${cfg.path}: $e');
        }
      }
    }
    _loaded = true;
  }

  Future<void> _writeYaml(String path, Map<String, dynamic> data) async {
    final f = File(path);
    await writeStringAtomic(f, _toYamlString(data));
  }

  /// Minimal YAML writer for flat maps (sufficient for workspace configs).
  String _toYamlString(Map<String, dynamic> data, {int indent = 0}) {
    final buf = StringBuffer();
    data.forEach((k, v) {
      buf.write('${'  ' * indent}$k:');
      if (v is Map) {
        buf.writeln();
        buf.write(
          _toYamlString(Map<String, dynamic>.from(v), indent: indent + 1),
        );
      } else if (v is List) {
        if (v.isEmpty) {
          buf.writeln(' []');
        } else {
          buf.writeln();
          for (final item in v) {
            if (item is Map) {
              buf.writeln('${'  ' * indent}- ');
              buf.write(
                _toYamlString(
                  Map<String, dynamic>.from(item),
                  indent: indent + 1,
                ),
              );
            } else {
              buf.writeln('${'  ' * indent}- ${_scalar(item)}');
            }
          }
        }
      } else {
        buf.writeln(' ${_scalar(v)}');
      }
    });
    return buf.toString();
  }

  String _scalar(Object? v) {
    if (v == null) return 'null';
    if (v is String) {
      if (v.contains(':') || v.contains('#'))
        return '"${v.replaceAll('"', '\\"')}"';
      return v;
    }
    return v.toString();
  }

  Map<String, dynamic> _toStringMap(Map<String, dynamic> m) {
    final out = <String, dynamic>{};
    m.forEach((k, v) {
      if (v is YamlMap) {
        out[k] = _toStringMap(Map<String, dynamic>.from(v));
      } else if (v is YamlList) {
        out[k] =
            v
                .map(
                  (e) =>
                      e is YamlMap
                          ? _toStringMap(Map<String, dynamic>.from(e))
                          : e,
                )
                .toList();
      } else {
        out[k] = v;
      }
    });
    return out;
  }
}
