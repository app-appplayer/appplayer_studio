/// `buildGlobalMemberList` + `orderWorkspacesHierarchical` — the aggregation and
/// ordering behind the `member_global_list` tool.
///
/// Regression for the headcount-undercount bug (konpi): member ids are unique
/// only WITHIN a workspace (every department owns its own `lead`, `qa`, …), so
/// the global list MUST key by `(workspaceId, id)`. Deduping on the short id
/// alone silently merged distinct department heads into one row and
/// undercounted the org (69 agents → 55 when 14 short ids collided).
///
/// Ordering: the list reads hierarchically like the org chart — workspaces in
/// depth-first `parentId` order (root → children, siblings by id), and within
/// each workspace persons (owner / CEO) above agents.
///
///   g1  same short id in two workspaces = two distinct rows (not merged)
///   g2  global total equals the sum of the per-workspace counts
///   g3  kindFilter excludes the other kind
///   g4  query filters by id or displayName substring (case-insensitive)
///   g5  rows carry workspaceId + agentId + kind-specific projection fields
///   o1  workspaces order depth-first: root → children, siblings by id
///   o2  a dangling / cyclic parent ref does not crash and is treated as a root
///   o3  within a workspace persons sort above agents; rows carry depth/parent
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/builtin_api.dart' show AgentRole;
import 'package:appplayer_studio/src/apps/ops/tools/system_tools.dart';
import 'package:appplayer_studio/src/apps/ops/registries/member_registry.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';

AgentMember _agent(String id, {String? name, AgentRole role = AgentRole.worker}) =>
    AgentMember(
  id: id,
  displayName: name ?? id,
  profileRef: '',
  skillIds: const [],
  philosophyRef: '',
  role: role,
);

PersonMember _person(String id, {String? name, String? email}) =>
    PersonMember(id: id, displayName: name ?? id, email: email);

Workspace _ws(
  String id, {
  String? parentId,
  WorkspaceUnitRole unitRole = WorkspaceUnitRole.line,
  int sortOrder = 0,
}) => Workspace(
  id: id,
  type: WorkspaceType.org,
  title: id,
  locale: 'en',
  timezone: 'UTC',
  createdAt: DateTime(2026),
  parentId: parentId,
  unitRole: unitRole,
  sortOrder: sortOrder,
);

/// One workspace tuple for buildGlobalMemberList (flat, depth 0, no parent).
({String wsId, String? parentId, int depth, List<Member> members}) _flat(
  String wsId,
  List<Member> members,
) => (wsId: wsId, parentId: null, depth: 0, members: members);

void main() {
  group('buildGlobalMemberList — (workspaceId, id) keying', () {
    test('g1 same short id in two workspaces = two distinct rows', () {
      final r = buildGlobalMemberList([
        _flat('org/sales', [_agent('lead', name: 'Sales Lead')]),
        _flat('org/eng', [_agent('lead', name: 'Eng Lead')]),
      ]);
      expect(r['total'], 2);
      final rows = (r['members'] as List).cast<Map<String, dynamic>>();
      expect(
        rows.map((e) => e['workspaceId']).toSet(),
        {'org/sales', 'org/eng'},
      );
      expect(rows.every((e) => e['id'] == 'lead'), isTrue);
    });

    test('g2 global total equals the sum of per-workspace counts', () {
      // 3 departments, each with a colliding lead + qa short id → 6 rows,
      // NOT deduped to 2 (the exact shape of konpi's 69→55 undercount).
      final r = buildGlobalMemberList([
        _flat('org/a', [_agent('lead'), _agent('qa')]),
        _flat('org/b', [_agent('lead'), _agent('qa')]),
        _flat('org/c', [_agent('lead'), _agent('qa')]),
      ]);
      expect(r['total'], 6);
    });

    test('g3 kindFilter excludes the other kind', () {
      final data = [
        _flat('org/a', [_agent('lead'), _person('owner')]),
        _flat('org/b', [_agent('lead')]),
      ];
      expect(buildGlobalMemberList(data, kindFilter: 'agent')['total'], 2);
      expect(buildGlobalMemberList(data, kindFilter: 'person')['total'], 1);
    });

    test('g4 query filters by id or displayName substring', () {
      final data = [
        _flat('org/a', [_agent('lead', name: 'Alice'), _agent('qa', name: 'Bob')]),
      ];
      expect(buildGlobalMemberList(data, query: 'lea')['total'], 1);
      expect(buildGlobalMemberList(data, query: 'BOB')['total'], 1);
      expect(buildGlobalMemberList(data, query: 'zzz')['total'], 0);
    });

    test('g5 rows carry workspaceId + agentId + projection fields', () {
      final r = buildGlobalMemberList([
        _flat('org/a', [_agent('lead', name: 'Lead')]),
        _flat('org/b', [_person('owner', email: 'o@x.com')]),
      ]);
      final rows = (r['members'] as List).cast<Map<String, dynamic>>();
      final agentRow = rows.firstWhere((e) => e['kind'] == 'agent');
      expect(agentRow['workspaceId'], 'org/a');
      expect(agentRow['agentId'], 'lead');
      expect(agentRow.containsKey('philosophyRef'), isTrue);
      final personRow = rows.firstWhere((e) => e['kind'] == 'person');
      expect(personRow['email'], 'o@x.com');
      expect(personRow.containsKey('roleLabels'), isTrue);
    });
  });

  group('orderWorkspacesHierarchical — org-tree order', () {
    test('o1 depth-first: root then children, siblings by id', () {
      // org ─┬ org/eng ── org/eng/frontend
      //      └ org/sales
      final ordered = orderWorkspacesHierarchical([
        _ws('org/sales', parentId: 'org'),
        _ws('org/eng/frontend', parentId: 'org/eng'),
        _ws('org', parentId: null),
        _ws('org/eng', parentId: 'org'),
      ]);
      expect(
        ordered.map((e) => e.ws.id).toList(),
        ['org', 'org/eng', 'org/eng/frontend', 'org/sales'],
      );
      expect(ordered.map((e) => e.depth).toList(), [0, 1, 2, 1]);
    });

    test('o2 dangling / cyclic parent ref is treated as a root, no crash', () {
      // 'x' points at a non-existent parent → root. 'a'⇄'b' cycle → both roots.
      final ordered = orderWorkspacesHierarchical([
        _ws('x', parentId: 'ghost'),
        _ws('a', parentId: 'b'),
        _ws('b', parentId: 'a'),
      ]);
      // All three surface exactly once (cycle guard prevents infinite walk).
      expect(ordered.map((e) => e.ws.id).toSet(), {'x', 'a', 'b'});
      expect(ordered.length, 3);
    });

    test('o2b staff siblings sort before line units, then by id', () {
      // Under 'org': the support unit must precede the operational units even
      // though its id sorts last alphabetically.
      final ordered = orderWorkspacesHierarchical([
        _ws('org', parentId: null),
        _ws('org/sales', parentId: 'org'),
        _ws('org/eng', parentId: 'org'),
        _ws('org/support', parentId: 'org', unitRole: WorkspaceUnitRole.staff),
      ]);
      expect(ordered.map((e) => e.ws.id).toList(), [
        'org',
        'org/support', // staff first despite 's' > 'e'
        'org/eng',
        'org/sales',
      ]);
    });

    test('o2c explicit sortOrder wins over staff-first + id, unset sorts last', () {
      // Operator lays out siblings in management-logic order via sortOrder;
      // a unit left unset (0) falls to the end regardless of unitRole.
      final ordered = orderWorkspacesHierarchical([
        _ws('org', parentId: null),
        _ws('org/sales', parentId: 'org', sortOrder: 3),
        _ws('org/eng', parentId: 'org', sortOrder: 2),
        _ws('org/support',
            parentId: 'org', unitRole: WorkspaceUnitRole.staff, sortOrder: 1),
        _ws('org/backoffice', parentId: 'org'), // unset → last
      ]);
      expect(ordered.map((e) => e.ws.id).toList(), [
        'org',
        'org/support', // sortOrder 1
        'org/eng', // sortOrder 2
        'org/sales', // sortOrder 3
        'org/backoffice', // unset → after all ordered
      ]);
    });
  });

  group('hierarchical listing', () {
    test('o3 persons sort above agents; rows carry depth + parentWorkspaceId', () {
      final r = buildGlobalMemberList([
        (
          wsId: 'org/sales',
          parentId: 'org',
          depth: 1,
          members: <Member>[_agent('lead'), _person('owner'), _agent('qa')],
        ),
      ]);
      final rows = (r['members'] as List).cast<Map<String, dynamic>>();
      // Person first, then agents by id.
      expect(rows.map((e) => e['id']).toList(), ['owner', 'lead', 'qa']);
      expect(rows.first['kind'], 'person');
      expect(rows.every((e) => e['depth'] == 1), isTrue);
      expect(rows.every((e) => e['parentWorkspaceId'] == 'org'), isTrue);
    });

    test('o3b root rows omit parentWorkspaceId', () {
      final r = buildGlobalMemberList([_flat('org', [_person('ceo')])]);
      final row = (r['members'] as List).cast<Map<String, dynamic>>().single;
      expect(row.containsKey('parentWorkspaceId'), isFalse);
      expect(row['depth'], 0);
    });

    test('o4 membersInListingOrder: persons first, then agents by id', () {
      // Shared by member_list + member_global_list — same intra-workspace order.
      final ordered = membersInListingOrder([
        _agent('qa'),
        _person('lawyer'),
        _agent('lead'),
        _person('ceo'),
      ]);
      expect(ordered.map((m) => m.id).toList(), ['ceo', 'lawyer', 'lead', 'qa']);
    });

    test('o4b membersInListingOrder: person → manager → reviewer → worker(id)', () {
      // The unit's manager (lead) leads the agent roster ahead of the
      // rank-and-file, even when its id sorts last alphabetically.
      final ordered = membersInListingOrder([
        _agent('zeta', role: AgentRole.manager), // manager despite 'z'
        _agent('cass'), // worker
        _person('owner'),
        _agent('rev', role: AgentRole.reviewer),
        _agent('abe'), // worker
      ]);
      expect(ordered.map((m) => m.id).toList(),
          ['owner', 'zeta', 'rev', 'abe', 'cass']);
    });
  });
}
