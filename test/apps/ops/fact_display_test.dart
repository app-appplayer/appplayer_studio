/// Unit tests for the shared fact-display helpers (UX audit P1) — the
/// classification + labelling that the domain Facts view and the Home activity
/// feed both rely on to keep `agent.*` lifecycle bookkeeping out of the user's
/// way and to show displayNames instead of raw qualified agentIds.
///
/// Scenarios:
///   fd1  isAgentLifecycleFact — `agent.*` types true, domain types false
///   fd2  isProvisioningFact — only `agent.fork.assigned` from a `pool:` source
///   fd3  isProvisioningFact — transfer (`agent:` source) is NOT provisioning
///   fd4  agentFactHeadline — readable wording per type (fork/transfer/evolve)
///   fd5  memberDisplayNameFor — resolves AgentMember.agentId → displayName
///   fd6  memberDisplayNameFor — unknown id falls back to last segment, never raw
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as bundle;
import 'package:appplayer_studio/src/apps/ops/registries/member_registry.dart';
import 'package:appplayer_studio/src/apps/ops/ui/_shared/fact_display.dart';

bundle.FactRecord _fact(
  String type, {
  Map<String, dynamic> content = const <String, dynamic>{},
}) => bundle.FactRecord(
  id: '$type/x',
  workspaceId: 'ws1',
  type: type,
  content: content,
  createdAt: DateTime.utc(2026, 7, 12),
);

AgentMember _agent(String id, String agentId, String name) => AgentMember(
  id: id,
  displayName: name,
  agentId: agentId,
  profileRef: 'p',
  skillIds: const <String>[],
  philosophyRef: 'ph',
);

void main() {
  group('isAgentLifecycleFact', () {
    test('fd1 agent.* true, domain false', () {
      expect(isAgentLifecycleFact('agent.fork.assigned'), isTrue);
      expect(isAgentLifecycleFact('agent.fork.evolved'), isTrue);
      expect(isAgentLifecycleFact('agent.invoked'), isTrue);
      expect(isAgentLifecycleFact('agent.deleted'), isTrue);
      expect(isAgentLifecycleFact('fact/domain/catalog'), isFalse);
      expect(isAgentLifecycleFact('kv:runbook'), isFalse);
    });
  });

  group('isProvisioningFact', () {
    test('fd2 fork.assigned from pool: is provisioning', () {
      expect(
        isProvisioningFact(
          _fact(
            'agent.fork.assigned',
            content: <String, dynamic>{'source': 'pool:philosophies/default'},
          ),
        ),
        isTrue,
      );
    });

    test('fd3 transfer (agent: source) and other types are NOT provisioning', () {
      expect(
        isProvisioningFact(
          _fact(
            'agent.fork.assigned',
            content: <String, dynamic>{'source': 'agent:noteui.ws.other'},
          ),
        ),
        isFalse,
      );
      expect(isProvisioningFact(_fact('agent.fork.evolved')), isFalse);
      expect(isProvisioningFact(_fact('agent.invoked')), isFalse);
    });
  });

  group('agentFactHeadline', () {
    test('fd4 readable wording per type', () {
      expect(
        agentFactHeadline(
          _fact(
            'agent.fork.assigned',
            content: <String, dynamic>{
              'axis': 'philosophy',
              'source': 'pool:philosophies/default',
            },
          ),
        ),
        'forked philosophy',
      );
      expect(
        agentFactHeadline(
          _fact(
            'agent.fork.assigned',
            content: <String, dynamic>{
              'axis': 'skill',
              'source': 'agent:x',
            },
          ),
        ),
        'received skill',
      );
      expect(
        agentFactHeadline(
          _fact(
            'agent.fork.evolved',
            content: <String, dynamic>{'axis': 'profile'},
          ),
        ),
        'profile evolved',
      );
      expect(agentFactHeadline(_fact('agent.invoked')), 'invoked');
      expect(agentFactHeadline(_fact('agent.deleted')), 'deleted');
    });
  });

  group('memberDisplayNameFor', () {
    final members = <Member>[
      _agent('proto', 'noteui.project_w.proto', 'Leo'),
      _agent('lead', 'makemind_ops.org_packages.lead', 'Kai'),
    ];

    test('fd5 resolves agentId → displayName', () {
      expect(
        memberDisplayNameFor(members, 'makemind_ops.org_packages.lead'),
        'Kai',
      );
      expect(memberDisplayNameFor(members, 'noteui.project_w.proto'), 'Leo');
    });

    test('fd6 unknown id → last segment, never the raw qualified id', () {
      expect(
        memberDisplayNameFor(members, 'project/w.gone.project_w.proto'),
        'proto',
      );
      expect(memberDisplayNameFor(const <Member>[], 'a.b.c'), 'c');
      // A bare (segment-less) id is returned as-is.
      expect(memberDisplayNameFor(const <Member>[], 'solo'), 'solo');
    });

    test('fd7 resolves a BARE member id → displayName (task assignee case)', () {
      // Task assigneeIds carry the short member id, not the qualified agentId.
      // The Home feed's task rows resolve through here; without the bare-id
      // match they fell back to the last-segment id ("proto") instead of the
      // displayName ("Leo") — the P1.3 residual konpi reported (2026-07-12).
      expect(memberDisplayNameFor(members, 'proto'), 'Leo');
      expect(memberDisplayNameFor(members, 'lead'), 'Kai');
    });

    test('fd8 person member bare id resolves too', () {
      final withPerson = <Member>[
        ...members,
        PersonMember(id: 'sam', displayName: 'Sam Ops', email: 's@x.io'),
      ];
      expect(memberDisplayNameFor(withPerson, 'sam'), 'Sam Ops');
    });
  });
}
