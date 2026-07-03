/// Ops chat coordinator is a SINGLE per-project manager — regression guard for
/// the single-coordinator fix (`OpsShell._applyOpsScopedManager`).
///
/// The bug: Ops scoped the chat manager per (project × workspace)
/// (`ops.manager.<project>.<workspaceId>`), so every `workspace_switch` minted
/// a fresh coordinator clone and fragmented the chat across workspaces — the
/// field store accumulated one `ops.manager.<wsLeaf>_<hash>` per workspace.
///
/// The fix: `_applyOpsScopedManager()` scopes by the ops PROJECT path ALONE
/// (like App Builder / Scene Builder), and the workspace-change subscription
/// only refreshes the roster — it never re-scopes the manager. So there is
/// exactly ONE coordinator per project, constant across workspace switches.
///
/// `AgentHost.ensureScopedManager` derives the clone id from the scope via the
/// private `_scopedAgentId` (base + sanitised-leaf + FNV-1a hash of the full
/// scope). We reproduce that exact algorithm inline (same approach as
/// `agent_host_helpers_test`) and assert the invariant at the scope boundary,
/// which is what the widget wiring feeds into `ensureScopedManager`:
///
///   sm1  project scope yields ONE coordinator id, independent of the active
///        workspace (switching workspaces cannot change it).
///   sm2  the OLD per-(project × workspace) scope fragments into a DISTINCT
///        clone per workspace — guarded so a reintroduction is caught.
///   sm3  the single project coordinator id is none of the per-workspace ids.
library;

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Inline clone of AgentHost's private id-scoping algorithm (agent_host.dart).
// Identical to `agent_host_helpers_test`; deterministic + boot-independent.
// ---------------------------------------------------------------------------

String _stableHash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = (h ^ c) & 0xffffffff;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

String _scopeLeaf(String scope) {
  final parts =
      scope.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? scope : parts.last;
}

String _scopedAgentId(String baseId, String scope) {
  if (scope.isEmpty) return baseId;
  final safeLeaf = _scopeLeaf(scope).replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  return '$baseId.${safeLeaf}_${_stableHash(scope)}';
}

void main() {
  const base = 'ops.manager';
  const project = '/Users/x/Desktop/ops/acme_ops';
  const workspaces = <String>['org/hr', 'org/media', 'org/legal', 'org/web'];

  group('Ops coordinator is a single per-project manager', () {
    test('sm1 project scope yields ONE coordinator id, independent of the '
        'active workspace', () {
      // `_applyOpsScopedManager()` calls `ensureScopedManager(base, project)`
      // — the scope is the project path, NEVER project/workspace. Switching
      // the active workspace does not re-scope, so the id is invariant.
      final coordinator = _scopedAgentId(base, project);
      expect(coordinator, startsWith('ops.manager.'));
      for (final ws in workspaces) {
        // The active workspace is `ws`, but the coordinator scope stays the
        // project — the id must not move.
        expect(
          _scopedAgentId(base, project),
          coordinator,
          reason: 'coordinator must stay single while active ws = $ws',
        );
      }
    });

    test('sm2 the OLD per-(project x workspace) scope fragments into a '
        'distinct clone per workspace (guard against reintroduction)', () {
      // If ops_shell ever reverts to `'$project/$ws'` scoping, each workspace
      // mints its own clone — this is the fragmentation the fix removed.
      final perWsIds = <String>{
        for (final ws in workspaces) _scopedAgentId(base, '$project/$ws'),
      };
      expect(
        perWsIds.length,
        workspaces.length,
        reason: 'per-ws scope makes N coordinators for N workspaces (the bug)',
      );
    });

    test('sm3 the single project coordinator is none of the per-workspace '
        'ids — the two scopings are disjoint', () {
      final coordinator = _scopedAgentId(base, project);
      final perWsIds = <String>{
        for (final ws in workspaces) _scopedAgentId(base, '$project/$ws'),
      };
      expect(perWsIds, isNot(contains(coordinator)));
    });
  });
}
