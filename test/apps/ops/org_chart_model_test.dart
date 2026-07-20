/// org_chart_model — deterministic event-topology layout.
///
///   t1  one process card node + step nodes inside + dep edges (linear default)
///   t2  parent→child hierarchy edge from `parentId`
///   t3  parallel branches — steps sharing a dependency share a level (same x,
///       stacked y), not a forced line
///   t4  event edge between processes via `triggerSource`; triggered card sits
///       in a later column
///   t5  approval gate → sign-off node above the gated step + sign-off edge
///   t6  philosophy gate → inline charter gate node
///   t7  agents not used by any process step → roster nodes
///   t8  deterministic — same input builds identical geometry
library;

import 'package:appplayer_studio/src/apps/ops/ui/organization/org_chart_model.dart';
import 'package:flutter/widgets.dart' show Rect;
import 'package:flutter_test/flutter_test.dart';

OrgWsInput _ws({
  required String id,
  String? parentId,
  String unitRole = 'line',
  List<OrgAgentInput> agents = const [],
  List<OrgProcessInput> processes = const [],
}) => OrgWsInput(
  id: id,
  title: id,
  type: 'org',
  parentId: parentId,
  unitRole: unitRole,
  agents: agents,
  processes: processes,
);

OrgStepInput _step(
  String stepId,
  String assignee, {
  String skill = '',
  List<String> dependsOn = const [],
}) => OrgStepInput(
  stepId: stepId,
  assigneeId: assignee,
  assigneeLabel: assignee,
  skillId: skill,
  dependsOn: dependsOn,
);

List<OrgNode> _steps(OrgChartModel m) =>
    m.nodes.where((n) => n.kind == OrgNodeKind.step).toList();

OrgNode _stepFor(OrgChartModel m, String stepId) =>
    m.nodes.firstWhere((n) => n.id.endsWith(':$stepId') && n.kind == OrgNodeKind.step);

void main() {
  test('t1 process card + step nodes + linear dep edges', () {
    final m = buildOrgChartModel([
      _ws(
        id: 'org/devmag',
        processes: [
          OrgProcessInput(
            id: 'article_pipeline',
            title: 'Article Pipeline',
            trigger: 'manual',
            steps: [
              _step('plan', 'planner'),
              _step('build', 'builder'),
              _step('publish', 'publisher'),
            ],
          ),
        ],
      ),
    ]);
    expect(
      m.nodes.where((n) => n.kind == OrgNodeKind.process), hasLength(1));
    expect(_steps(m), hasLength(3));
    // Default = linear chain: 2 dep edges (plan→build→publish).
    final deps = m.edges.where((e) => e.kind == OrgEdgeKind.dep).toList();
    expect(deps, hasLength(2));
    // Linear ⇒ each step in its own level ⇒ strictly increasing x.
    final plan = _stepFor(m, 'plan');
    final build = _stepFor(m, 'build');
    final publish = _stepFor(m, 'publish');
    expect(plan.rect.left, lessThan(build.rect.left));
    expect(build.rect.left, lessThan(publish.rect.left));
  });

  test('t2 hierarchy edge from parentId', () {
    final m = buildOrgChartModel([
      _ws(id: 'makemind_ops'),
      _ws(id: 'org/devmag', parentId: 'makemind_ops'),
    ]);
    expect(
      m.edges.any((e) =>
          e.kind == OrgEdgeKind.hierarchy &&
          e.fromId == 'ws:makemind_ops' &&
          e.toId == 'ws:org/devmag'),
      isTrue,
    );
  });

  test('t3 parallel branches share a level (same x, stacked y)', () {
    final m = buildOrgChartModel([
      _ws(
        id: 'w',
        processes: [
          OrgProcessInput(
            id: 'p',
            title: 'P',
            steps: [
              _step('build', 'builder'),
              _step('shoot', 'shooter', dependsOn: ['build']),
              _step('design', 'designer', dependsOn: ['build']),
            ],
          ),
        ],
      ),
    ]);
    final build = _stepFor(m, 'build');
    final shoot = _stepFor(m, 'shoot');
    final design = _stepFor(m, 'design');
    // shoot & design both depend on build ⇒ same level (same x), past build.
    expect(shoot.rect.left, greaterThan(build.rect.left));
    expect(shoot.rect.left, equals(design.rect.left));
    // …and stacked vertically (parallel lanes), not on the same row.
    expect(shoot.rect.top, isNot(equals(design.rect.top)));
    // Two dep edges, both from build.
    final deps = m.edges.where((e) => e.kind == OrgEdgeKind.dep).toList();
    expect(deps, hasLength(2));
    expect(deps.every((e) => e.fromId == build.id), isTrue);
  });

  test('t4 event edge between processes; triggered card in later column', () {
    final m = buildOrgChartModel([
      _ws(
        id: 'w',
        processes: [
          OrgProcessInput(
            id: 'a',
            title: 'A',
            trigger: 'manual',
            steps: [_step('s', 'x')],
          ),
          OrgProcessInput(
            id: 'b',
            title: 'B',
            trigger: 'event',
            triggerSource: 'a',
            steps: [_step('s', 'y')],
          ),
        ],
      ),
    ]);
    final cardA = m.nodes.firstWhere((n) => n.id == 'pc:w:a');
    final cardB = m.nodes.firstWhere((n) => n.id == 'pc:w:b');
    expect(
      m.edges.any((e) =>
          e.kind == OrgEdgeKind.event &&
          e.fromId == 'pc:w:a' &&
          e.toId == 'pc:w:b'),
      isTrue,
    );
    // B is event-triggered by A ⇒ placed in a later (right) column.
    expect(cardB.rect.left, greaterThan(cardA.rect.left));
    expect(cardB.badge, 'event');
  });

  test('t5 approval gate → INLINE sign-off chip on the flow line', () {
    final m = buildOrgChartModel([
      _ws(
        id: 'w',
        processes: [
          OrgProcessInput(
            id: 'p',
            title: 'P',
            steps: [_step('plan', 'planner'), _step('publish', 'publisher')],
            gates: const [
              OrgGateInput(
                afterStep: 'plan',
                kind: 'approval',
                approverId: 'publisher',
                approverLabel: 'publisher',
              ),
            ],
          ),
        ],
      ),
    ]);
    final so = m.nodes.where((n) => n.kind == OrgNodeKind.signoff).toList();
    expect(so, hasLength(1));
    expect(so.first.agentId, 'publisher');
    expect(so.first.sublabel, 'sign-off');
    final plan = _stepFor(m, 'plan');
    final publish = _stepFor(m, 'publish');
    // INLINE on the flow line: after the gated step, lane-centered, and the
    // successor sits beyond the chip (the gap absorbed the slot).
    expect(so.first.rect.left, greaterThan(plan.rect.right));
    expect(publish.rect.left, greaterThan(so.first.rect.right));
    expect(
      so.first.rect.center.dy,
      moreOrLessEquals(plan.rect.center.dy, epsilon: 0.001),
    );
    // Flow routes THROUGH the gate: step→chip and chip→successor, and the
    // direct dep edge between the two steps is gone.
    expect(
      m.edges.any((e) =>
          e.kind == OrgEdgeKind.signoff &&
          e.fromId == plan.id &&
          e.toId == so.first.id),
      isTrue,
    );
    expect(
      m.edges.any((e) =>
          e.kind == OrgEdgeKind.signoff &&
          e.fromId == so.first.id &&
          e.toId == publish.id),
      isTrue,
    );
    expect(
      m.edges.any((e) =>
          e.kind == OrgEdgeKind.dep &&
          e.fromId == plan.id &&
          e.toId == publish.id),
      isFalse,
    );
  });

  test('t6 philosophy gate → inline charter gate node', () {
    final m = buildOrgChartModel([
      _ws(
        id: 'w',
        processes: [
          OrgProcessInput(
            id: 'p',
            title: 'P',
            steps: [_step('copyedit', 'copyeditor'), _step('done', 'editor')],
            gates: const [
              OrgGateInput(afterStep: 'copyedit', kind: 'philosophy'),
            ],
          ),
        ],
      ),
    ]);
    final gates = m.nodes.where((n) => n.kind == OrgNodeKind.gate).toList();
    expect(gates, hasLength(1));
    expect(gates.first.label, 'charter');
    expect(gates.first.processId, 'p');
  });

  test('t7 agents not in any process → roster nodes', () {
    final m = buildOrgChartModel([
      _ws(
        id: 'w',
        agents: const [
          OrgAgentInput(agentId: 'planner', displayName: 'Planner'),
          OrgAgentInput(agentId: 'lurker', displayName: 'Lurker'),
        ],
        processes: [
          OrgProcessInput(
            id: 'p',
            title: 'P',
            steps: [_step('plan', 'planner')],
          ),
        ],
      ),
    ]);
    final roster = m.nodes.where((n) => n.kind == OrgNodeKind.agent).toList();
    expect(roster, hasLength(1));
    expect(roster.first.agentId, 'lurker');
  });

  test('t9 structure lens groups members by role', () {
    final m = buildOrgChartModel([
      _ws(
        id: 'w',
        agents: const [
          OrgAgentInput(agentId: 'a1', displayName: 'A1', role: 'writer'),
          OrgAgentInput(agentId: 'a2', displayName: 'A2', role: 'writer'),
          OrgAgentInput(agentId: 'a3', displayName: 'A3', role: 'editor'),
        ],
      ),
    ], mode: OrgViewMode.structure);
    final roleHeaders =
        m.nodes.where((n) => n.kind == OrgNodeKind.role).toList();
    expect(roleHeaders.map((n) => n.label).toSet(), {'writer', 'editor'});
    // No process / step nodes in the structure lens.
    expect(m.nodes.where((n) => n.kind == OrgNodeKind.step), isEmpty);
    expect(m.nodes.where((n) => n.kind == OrgNodeKind.agent), hasLength(3));
  });

  test('t10 knowledge lens links members to referenced knowledge', () {
    final m = buildOrgChartModel([
      _ws(
        id: 'w',
        agents: const [
          OrgAgentInput(
            agentId: 'writer',
            displayName: 'Writer',
            role: 'writer',
            skillRefs: ['write_article'],
            profileRef: 'voice-writer',
            philosophyRef: 'voice-honest',
          ),
        ],
      ),
    ], mode: OrgViewMode.knowledge);
    final kn = m.nodes.where((n) => n.kind == OrgNodeKind.knowledge).toList();
    // 3 distinct knowledge refs (skill + profile + philosophy).
    expect(kn, hasLength(3));
    expect(kn.map((n) => n.sublabel).toSet(), {'skill', 'profile', 'philosophy'});
    // Ownership edges from the member to each.
    final own =
        m.edges.where((e) => e.kind == OrgEdgeKind.ownership).toList();
    expect(own, hasLength(3));
    expect(own.every((e) => e.fromId == 'ag:w:writer'), isTrue);
  });

  test('t11 structure lens — lead on top + reports edges to members', () {
    final m = buildOrgChartModel([
      OrgWsInput(
        id: 'w',
        title: 'W',
        type: 'org',
        leadMemberId: 'editor',
        agents: const [
          OrgAgentInput(agentId: 'editor', displayName: 'Editor', role: 'manager'),
          OrgAgentInput(agentId: 'writer', displayName: 'Writer'),
          OrgAgentInput(agentId: 'shooter', displayName: 'Shooter', isAgent: false),
        ],
      ),
    ], mode: OrgViewMode.structure);
    final lead = m.nodes.firstWhere((n) => n.isLead);
    expect(lead.agentId, 'editor');
    // Lead sits above the other members.
    final members = m.nodes
        .where((n) => n.kind == OrgNodeKind.agent && !n.isLead)
        .toList();
    expect(members, hasLength(2));
    expect(members.every((mn) => mn.rect.top > lead.rect.top), isTrue);
    // Reporting edges lead → each member.
    final reports = m.edges.where((e) => e.kind == OrgEdgeKind.reports).toList();
    expect(reports, hasLength(2));
    expect(reports.every((e) => e.fromId == lead.id), isTrue);
    // Human flag carried (👤 icon).
    expect(m.nodes.firstWhere((n) => n.agentId == 'shooter').isAgent, isFalse);
  });

  test('t12 structure role label = profile (persona)', () {
    final m = buildOrgChartModel([
      OrgWsInput(
        id: 'w',
        title: 'W',
        type: 'org',
        leadMemberId: 'lead',
        agents: const [
          OrgAgentInput(
            agentId: 'lead',
            displayName: 'Lead',
            role: 'manager',
            profileRef: 'profiles/tech-lead',
          ),
          OrgAgentInput(
            agentId: 'w1',
            displayName: 'Worker',
            role: 'worker',
            profileRef: 'voice-eng',
          ),
        ],
      ),
    ], mode: OrgViewMode.structure);
    // Role shown = the profile (persona), not the free-text role tag.
    final lead = m.nodes.firstWhere((n) => n.isLead);
    expect(lead.sublabel, 'lead · tech-lead'); // profiles/ prefix stripped
    final worker = m.nodes.firstWhere(
        (n) => n.kind == OrgNodeKind.agent && !n.isLead);
    expect(worker.sublabel, 'voice-eng');
  });

  test('t13 structure lens — top-down tree: parent centered above children,'
      ' siblings never overlap', () {
    final m = buildOrgChartModel([
      _ws(id: 'org', agents: [OrgAgentInput(agentId: 'boss', displayName: 'Boss')]),
      _ws(id: 'org/a', parentId: 'org', agents: [OrgAgentInput(agentId: 'a1', displayName: 'A1'), OrgAgentInput(agentId: 'a2', displayName: 'A2')]),
      _ws(id: 'org/b', parentId: 'org', agents: [OrgAgentInput(agentId: 'b1', displayName: 'B1')]),
    ], mode: OrgViewMode.structure);
    Rect unit(String id) =>
        m.nodes.firstWhere((n) => n.id == 'ws:$id').rect;
    final root = unit('org');
    final a = unit('org/a');
    final b = unit('org/b');
    // Children sit BELOW the parent on the same row.
    expect(a.top, greaterThan(root.bottom));
    expect(b.top, a.top);
    // Siblings don't overlap.
    final noOverlap = a.right <= b.left || b.right <= a.left;
    expect(noOverlap, isTrue);
    // Parent is centered over the span of its children.
    final span = a.expandToInclude(b);
    expect(
      root.center.dx,
      moreOrLessEquals(span.center.dx, epsilon: 1.0),
    );
    // Hierarchy edges parent→child exist for both.
    expect(
      m.edges
          .where((e) => e.kind == OrgEdgeKind.hierarchy && e.fromId == 'ws:org')
          .length,
      2,
    );
  });

  test('t13b structure lens — line is the centered spine; staff steps aside to'
      ' the RIGHT of the stem, in the band above the line row', () {
    final m = buildOrgChartModel([
      _ws(id: 'org', agents: [OrgAgentInput(agentId: 'boss', displayName: 'Boss')]),
      _ws(id: 'org/support', parentId: 'org', unitRole: 'staff'),
      _ws(id: 'org/eng', parentId: 'org'),
    ], mode: OrgViewMode.structure);
    Rect unit(String id) => m.nodes.firstWhere((n) => n.id == 'ws:$id').rect;
    final root = unit('org');
    final support = unit('org/support');
    final eng = unit('org/eng');
    // Staff (support) is in the band below the parent — not the far-left edge.
    expect(support.top, greaterThan(root.bottom));
    // ...and offset to the RIGHT of the central stem (not centered on it).
    expect(support.left, greaterThan(root.center.dx));
    // Line (operational) is the centered spine, below the staff band.
    expect(eng.center.dx, moreOrLessEquals(root.center.dx, epsilon: 1.0));
    expect(eng.top, greaterThan(support.bottom));
    // Staff is wired with a sideStub edge, line with a hierarchy edge.
    expect(
      m.edges.any((e) => e.kind == OrgEdgeKind.sideStub &&
          e.fromId == 'ws:org' && e.toId == 'ws:org/support'),
      isTrue,
    );
    expect(
      m.edges.any((e) => e.kind == OrgEdgeKind.hierarchy &&
          e.fromId == 'ws:org' && e.toId == 'ws:org/eng'),
      isTrue,
    );
  });

  test('t13c structure lens — the central stem stays clear: staff sits right'
      ' of it and the line row (centered) is pushed below the staff band', () {
    // Two staff units + two line units, mirroring the HQ shape in the report.
    final m = buildOrgChartModel([
      _ws(id: 'org', agents: [OrgAgentInput(agentId: 'boss', displayName: 'Boss')]),
      _ws(id: 'org/s1', parentId: 'org', unitRole: 'staff'),
      _ws(id: 'org/s2', parentId: 'org', unitRole: 'staff'),
      _ws(id: 'org/l1', parentId: 'org'),
      _ws(id: 'org/l2', parentId: 'org'),
    ], mode: OrgViewMode.structure);
    Rect unit(String id) => m.nodes.firstWhere((n) => n.id == 'ws:$id').rect;
    final root = unit('org');
    final staffBottom =
        [unit('org/s1').bottom, unit('org/s2').bottom].reduce((a, b) => a > b ? a : b);
    final lineTop =
        [unit('org/l1').top, unit('org/l2').top].reduce((a, b) => a < b ? a : b);
    // The entire line tier starts below the entire staff band.
    expect(lineTop, greaterThan(staffBottom));
    // The whole staff row sits to the RIGHT of the central stem.
    final staffLeft =
        [unit('org/s1').left, unit('org/s2').left].reduce((a, b) => a < b ? a : b);
    expect(staffLeft, greaterThan(root.center.dx));
    // Staff siblings sit side by side in one row (same top), no overlap.
    expect(unit('org/s1').top, moreOrLessEquals(unit('org/s2').top, epsilon: 1.0));
    final s1 = unit('org/s1'), s2 = unit('org/s2');
    expect(s1.right <= s2.left || s2.right <= s1.left, isTrue);
    // The line row is centered on the stem (span center ≈ parent center).
    final lineSpan = unit('org/l1').expandToInclude(unit('org/l2'));
    expect(lineSpan.center.dx, moreOrLessEquals(root.center.dx, epsilon: 1.0));
  });

  test('t8 deterministic geometry', () {
    List<OrgWsInput> input() => [
      _ws(id: 'a', processes: [
        OrgProcessInput(
          id: 'p',
          title: 'P',
          steps: [
            _step('s1', 'x'),
            _step('s2', 'y', dependsOn: ['s1']),
            _step('s3', 'z', dependsOn: ['s1']),
          ],
          gates: const [OrgGateInput(afterStep: 's1', kind: 'philosophy')],
        ),
      ]),
      _ws(id: 'b', parentId: 'a'),
    ];
    final m1 = buildOrgChartModel(input());
    final m2 = buildOrgChartModel(input());
    expect(m1.size, m2.size);
    expect(m1.nodes.length, m2.nodes.length);
    for (var i = 0; i < m1.nodes.length; i++) {
      expect(m1.nodes[i].rect, m2.nodes[i].rect);
      expect(m1.nodes[i].id, m2.nodes[i].id);
    }
  });

  // Canonical sibling ordering — shared by chart layout, directory nav, and
  // card tree so every lens reads the same order as the Home switcher.
  group('orgWsSiblingCompare', () {
    OrgWsInput ws(String id, {int sortOrder = 0, String unitRole = 'line'}) =>
        OrgWsInput(
          id: id,
          title: id,
          type: 'org',
          sortOrder: sortOrder,
          unitRole: unitRole,
        );

    List<String> ordered(List<OrgWsInput> ws) =>
        ([...ws]..sort(orgWsSiblingCompare)).map((w) => w.id).toList();

    test('explicit sortOrder ascending wins; 0 (unset) sorts last', () {
      expect(
        ordered([ws('z', sortOrder: 1), ws('a'), ws('m', sortOrder: 2)]),
        ['z', 'm', 'a'],
      );
    });

    test('staff before line when sortOrder is unset, then by id', () {
      expect(
        ordered([
          ws('org/tech-group'),
          ws('org/staff', unitRole: 'staff'),
          ws('org/backoffice', unitRole: 'staff'),
        ]),
        ['org/backoffice', 'org/staff', 'org/tech-group'],
      );
    });

    test('does not fall back to raw id order (the reported bug)', () {
      // Operator intent via sortOrder must beat alphabetical-by-id.
      final byOrder = ordered([
        ws('org/content', sortOrder: 7),
        ws('org/backoffice', sortOrder: 1),
        ws('org/biz-group', sortOrder: 5),
      ]);
      expect(byOrder, ['org/backoffice', 'org/biz-group', 'org/content']);
      // Sanity: a pure id sort would have kept backoffice/biz-group/content by
      // coincidence here, so flip one to prove sortOrder is the key.
      expect(
        ordered([
          ws('org/backoffice', sortOrder: 9),
          ws('org/biz-group', sortOrder: 1),
        ]),
        ['org/biz-group', 'org/backoffice'],
      );
    });
  });
}
