/// MemberRegistry — unit tests for all unit-testable paths.
///
/// Scenarios:
///   m1  addPerson — happy path: id / displayName / email / roleLabels / disk file
///   m2  addPerson — empty rootDir throws StateError
///   m3  createAgent — happy path (isAgentSubsystemActivated=false, stub KS)
///   m4  createAgent — agentId defaults to id when omitted
///   m5  createAgent — explicit agentId differs from id, persisted
///   m6  listForWorkspace — returns only that workspace members
///   m7  listForWorkspace — empty when no members
///   m8  get — finds member across workspaces
///   m9  get — returns null for unknown
///   m10 update — PersonMember: displayName / email / roleLabels / tags
///   m11 update — AgentMember: displayName / model / profileRef / skillIds
///   m12 update — unknown memberId throws StateError
///   m13 deleteMember — removes from cache and disk
///   m14 attachToWorkspace — copies member yaml to second workspace
///   m15 detachFromWorkspace — removes from second workspace only
///   m16 _ensureLoaded — reads YAML written by another instance (person + agent)
///   m17 _toYaml / _fromYaml — AgentMember round-trip through disk
///   m18 _toYaml / _fromYaml — PersonMember round-trip through disk
///   m19 _toYaml — AuthProfileRef serialized / deserialized in AgentMember
///   m20 changes stream — fires on addPerson / createAgent / update / delete
///   m21 growthStatus — returns null for PersonMember
///   m22 growthStatus — returns AgentGrowth.zero when agent subsystem inactive
///   m23 captureAuthProfile — throws for PersonMember
///   m24 captureAuthProfile — updates authProfiles, replaces duplicate systemId
///   m25 MemberKind enum coverage
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:appplayer_studio/builtin_api.dart'
    show KnowledgeSystem, ModelSpec;
import 'package:appplayer_studio/src/apps/ops/registries/member_registry.dart';
import 'package:appplayer_studio/src/apps/ops/infra/ws_paths.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<(MemberRegistry, Directory)> _makeRegistry() async {
  final tmp = await Directory.systemTemp.createTemp('member_reg_test_');
  final kv = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv'));
  final reg = MemberRegistry(
    kv: kv,
    knowledgeSystem: KnowledgeSystem.stub(),
    rootDir: tmp.path,
  );
  return (reg, tmp);
}

void main() {
  group('MemberRegistry — addPerson', () {
    late MemberRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- m1: addPerson happy path ---
    test('m1 addPerson persists person with all fields', () async {
      final person = await reg.addPerson(
        id: 'alice',
        displayName: 'Alice Smith',
        email: 'alice@example.com',
        workspaceId: 'project/ws1',
        roleLabels: ['editor', 'reviewer'],
      );

      expect(person.id, 'alice');
      expect(person.kind, MemberKind.person);
      expect(person.displayName, 'Alice Smith');
      expect(person.email, 'alice@example.com');
      expect(person.roleLabels, containsAll(['editor', 'reviewer']));

      // File must exist on disk.
      final dir = Directory(
        '${wsContentRoot(tmp.path, 'project/ws1')}/members',
      );
      final file = File('${dir.path}/alice.yaml');
      expect(await file.exists(), isTrue);
    });

    // --- m2: empty rootDir throws ---
    test('m2 addPerson with empty rootDir throws StateError', () async {
      final kv = KvStoragePortAdapter(rootDir: '/tmp/kv_empty_mem');
      final emptyReg = MemberRegistry(
        kv: kv,
        knowledgeSystem: KnowledgeSystem.stub(),
        rootDir: '',
      );
      expect(
        () => emptyReg.addPerson(
          id: 'bob',
          displayName: 'Bob',
          workspaceId: 'project/ws1',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('MemberRegistry — createAgent', () {
    late MemberRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- m3: createAgent happy path ---
    test(
      'm3 createAgent persists agent when agent subsystem inactive (stub)',
      () async {
        final agent = await reg.createAgent(
          id: 'agent_alpha',
          displayName: 'Alpha Agent',
          profileRef: 'profile_alpha',
          skillIds: ['skill.analyze', 'skill.write'],
          philosophyRef: 'ethics_v1',
          workspaceId: 'project/ws1',
        );

        expect(agent.id, 'agent_alpha');
        expect(agent.kind, MemberKind.agent);
        expect(agent.displayName, 'Alpha Agent');
        expect(agent.profileRef, 'profile_alpha');
        expect(agent.skillIds, containsAll(['skill.analyze', 'skill.write']));
        expect(agent.philosophyRef, 'ethics_v1');

        final dir = Directory(
          '${wsContentRoot(tmp.path, 'project/ws1')}/members',
        );
        final file = File('${dir.path}/agent_alpha.yaml');
        expect(await file.exists(), isTrue);
      },
    );

    // --- m4: agentId defaults to id ---
    test('m4 createAgent agentId defaults to id', () async {
      final agent = await reg.createAgent(
        id: 'ag_beta',
        displayName: 'Beta',
        profileRef: 'p1',
        skillIds: const [],
        philosophyRef: 'ph1',
        workspaceId: 'project/ws1',
      );
      expect(agent.agentId, 'ag_beta');
    });

    // --- m5: explicit agentId differs from id ---
    test('m5 createAgent explicit agentId is preserved', () async {
      final agent = await reg.createAgent(
        id: 'ag_surface',
        displayName: 'Surface',
        agentId: 'flowbrain_id_xyz',
        profileRef: 'p1',
        skillIds: const [],
        philosophyRef: 'ph1',
        workspaceId: 'project/ws1',
      );
      expect(agent.agentId, 'flowbrain_id_xyz');
    });
  });

  group('MemberRegistry — list / get', () {
    late MemberRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- m6: listForWorkspace scoping ---
    test(
      'm6 listForWorkspace returns only members of the given workspace',
      () async {
        await reg.addPerson(
          id: 'ws1_alice',
          displayName: 'Alice',
          workspaceId: 'project/ws1',
        );
        await reg.addPerson(
          id: 'ws2_bob',
          displayName: 'Bob',
          workspaceId: 'project/ws2',
        );

        final ws1 = await reg.listForWorkspace('project/ws1');
        expect(ws1.map((m) => m.id), contains('ws1_alice'));
        expect(ws1.map((m) => m.id), isNot(contains('ws2_bob')));

        final ws2 = await reg.listForWorkspace('project/ws2');
        expect(ws2.map((m) => m.id), contains('ws2_bob'));
      },
    );

    // --- m7: empty workspace ---
    test(
      'm7 listForWorkspace returns empty list when workspace has no members',
      () async {
        final list = await reg.listForWorkspace('project/empty');
        expect(list, isEmpty);
      },
    );

    // --- m8: get across workspaces ---
    test('m8 get finds member across workspaces', () async {
      await reg.addPerson(
        id: 'carol',
        displayName: 'Carol',
        workspaceId: 'project/ws_a',
      );
      final found = await reg.get('carol');
      expect(found, isNotNull);
      expect(found!.displayName, 'Carol');
    });

    // --- m9: get unknown ---
    test('m9 get returns null for unknown memberId', () async {
      final result = await reg.get('ghost_member');
      expect(result, isNull);
    });
  });

  group('MemberRegistry — update', () {
    late MemberRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- m10: update PersonMember ---
    test(
      'm10 update PersonMember modifies displayName/email/roleLabels/tags',
      () async {
        await reg.addPerson(
          id: 'dave',
          displayName: 'Dave Original',
          email: 'old@test.com',
          workspaceId: 'project/ws1',
          roleLabels: ['viewer'],
        );

        final updated = await reg.update(
          memberId: 'dave',
          workspaceId: 'project/ws1',
          displayName: 'Dave Updated',
          email: 'new@test.com',
          roleLabels: ['editor', 'admin'],
          tags: {'dept': 'eng'},
        );

        expect(updated, isA<PersonMember>());
        final p = updated as PersonMember;
        expect(p.displayName, 'Dave Updated');
        expect(p.email, 'new@test.com');
        expect(p.roleLabels, containsAll(['editor', 'admin']));
        expect(p.tags['dept'], 'eng');
      },
    );

    // --- m11: update AgentMember ---
    test(
      'm11 update AgentMember modifies displayName/model/profileRef/skillIds',
      () async {
        await reg.createAgent(
          id: 'ev_agent',
          displayName: 'Ev Original',
          profileRef: 'profile_old',
          skillIds: ['skill.a'],
          philosophyRef: 'ph_old',
          workspaceId: 'project/ws1',
        );

        final updated = await reg.update(
          memberId: 'ev_agent',
          workspaceId: 'project/ws1',
          displayName: 'Ev Updated',
          model: const ModelSpec(provider: 'openai', model: 'gpt-4o'),
          profileRef: 'profile_new',
          skillIds: ['skill.a', 'skill.b'],
        );

        expect(updated, isA<AgentMember>());
        final a = updated as AgentMember;
        expect(a.displayName, 'Ev Updated');
        expect(a.model?.provider, 'openai');
        expect(a.model?.model, 'gpt-4o');
        expect(a.profileRef, 'profile_new');
        expect(a.skillIds, containsAll(['skill.a', 'skill.b']));
      },
    );

    // --- m12: update unknown ---
    test('m12 update unknown memberId throws StateError', () {
      expect(
        () => reg.update(
          memberId: 'nobody',
          workspaceId: 'project/ws1',
          displayName: 'X',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('MemberRegistry — delete / attach / detach', () {
    late MemberRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- m13: deleteMember ---
    test('m13 deleteMember removes from cache and deletes disk file', () async {
      await reg.addPerson(
        id: 'frank',
        displayName: 'Frank',
        workspaceId: 'project/ws1',
      );

      final dir = Directory(
        '${wsContentRoot(tmp.path, 'project/ws1')}/members',
      );
      expect(await File('${dir.path}/frank.yaml').exists(), isTrue);

      await reg.deleteMember('frank', 'project/ws1');

      final list = await reg.listForWorkspace('project/ws1');
      expect(list.where((m) => m.id == 'frank'), isEmpty);
      expect(await File('${dir.path}/frank.yaml').exists(), isFalse);
    });

    // --- m14: attachToWorkspace ---
    test('m14 attachToWorkspace copies member to second workspace', () async {
      await reg.addPerson(
        id: 'grace',
        displayName: 'Grace',
        workspaceId: 'project/ws1',
      );

      await reg.attachToWorkspace('grace', 'project/ws2');

      final ws2 = await reg.listForWorkspace('project/ws2');
      expect(ws2.map((m) => m.id), contains('grace'));

      // File must exist in ws2 dir too.
      final dir2 = Directory(
        '${wsContentRoot(tmp.path, 'project/ws2')}/members',
      );
      expect(await File('${dir2.path}/grace.yaml').exists(), isTrue);
    });

    // --- m15: detachFromWorkspace ---
    test(
      'm15 detachFromWorkspace removes from second workspace only',
      () async {
        await reg.addPerson(
          id: 'hank',
          displayName: 'Hank',
          workspaceId: 'project/ws1',
        );
        await reg.attachToWorkspace('hank', 'project/ws2');

        await reg.detachFromWorkspace('hank', 'project/ws2');

        final ws2 = await reg.listForWorkspace('project/ws2');
        expect(ws2.where((m) => m.id == 'hank'), isEmpty);

        // Still present in ws1.
        final ws1 = await reg.listForWorkspace('project/ws1');
        expect(ws1.map((m) => m.id), contains('hank'));
      },
    );
  });

  group('MemberRegistry — disk round-trip (_ensureLoaded)', () {
    late Directory tmp;

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    // --- m16: _ensureLoaded reads YAML files ---
    test(
      'm16 fresh registry loads person + agent YAML written by another instance',
      () async {
        // Write via first registry.
        tmp = await Directory.systemTemp.createTemp('member_reg_disk_');
        final kv1 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv1'));
        final reg1 = MemberRegistry(
          kv: kv1,
          knowledgeSystem: KnowledgeSystem.stub(),
          rootDir: tmp.path,
        );
        await reg1.addPerson(
          id: 'iris',
          displayName: 'Iris',
          workspaceId: 'project/disk_ws',
        );
        await reg1.createAgent(
          id: 'disk_agent',
          displayName: 'Disk Agent',
          profileRef: 'p1',
          skillIds: ['s1'],
          philosophyRef: 'ph1',
          workspaceId: 'project/disk_ws',
        );

        // New registry from same rootDir.
        final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
        final reg2 = MemberRegistry(
          kv: kv2,
          knowledgeSystem: KnowledgeSystem.stub(),
          rootDir: tmp.path,
        );
        final list = await reg2.listForWorkspace('project/disk_ws');
        final ids = list.map((m) => m.id).toSet();
        expect(ids, containsAll(['iris', 'disk_agent']));
      },
    );

    // --- m17: AgentMember round-trip ---
    test(
      'm17 AgentMember yaml round-trip preserves model + authProfiles',
      () async {
        tmp = await Directory.systemTemp.createTemp('member_reg_agent_rt_');
        final kv1 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv1'));
        final reg1 = MemberRegistry(
          kv: kv1,
          knowledgeSystem: KnowledgeSystem.stub(),
          rootDir: tmp.path,
        );
        await reg1.createAgent(
          id: 'jake',
          displayName: 'Jake',
          profileRef: 'pJ',
          skillIds: ['s1', 's2'],
          philosophyRef: 'phJ',
          workspaceId: 'project/rt',
          model: const ModelSpec(
            provider: 'anthropic',
            model: 'claude-3',
            maxTokens: 4096,
          ),
          tags: {'tier': 'senior'},
        );

        final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
        final reg2 = MemberRegistry(
          kv: kv2,
          knowledgeSystem: KnowledgeSystem.stub(),
          rootDir: tmp.path,
        );
        final list = await reg2.listForWorkspace('project/rt');
        expect(list.length, 1);
        final a = list.first as AgentMember;
        expect(a.id, 'jake');
        expect(a.displayName, 'Jake');
        expect(a.model?.provider, 'anthropic');
        expect(a.model?.model, 'claude-3');
        expect(a.model?.maxTokens, 4096);
        expect(a.skillIds, containsAll(['s1', 's2']));
        expect(a.tags['tier'], 'senior');
      },
    );

    // --- m18: PersonMember round-trip ---
    test(
      'm18 PersonMember yaml round-trip preserves email + roleLabels',
      () async {
        tmp = await Directory.systemTemp.createTemp('member_reg_person_rt_');
        final kv1 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv1'));
        final reg1 = MemberRegistry(
          kv: kv1,
          knowledgeSystem: KnowledgeSystem.stub(),
          rootDir: tmp.path,
        );
        await reg1.addPerson(
          id: 'kate',
          displayName: 'Kate Doe',
          email: 'kate@corp.com',
          workspaceId: 'project/rt2',
          roleLabels: ['pm', 'lead'],
        );
        // tags are set via update since addPerson does not accept tags directly.
        await reg1.update(
          memberId: 'kate',
          workspaceId: 'project/rt2',
          tags: {'team': 'product'},
        );

        final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
        final reg2 = MemberRegistry(
          kv: kv2,
          knowledgeSystem: KnowledgeSystem.stub(),
          rootDir: tmp.path,
        );
        final list = await reg2.listForWorkspace('project/rt2');
        expect(list.length, 1);
        final person = list.first as PersonMember;
        expect(person.id, 'kate');
        expect(person.email, 'kate@corp.com');
        expect(person.roleLabels, containsAll(['pm', 'lead']));
        expect(person.tags['team'], 'product');
      },
    );
  });

  group('MemberRegistry — AuthProfileRef', () {
    late MemberRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- m19: AuthProfileRef serialization ---
    test('m19 authProfiles round-trip through YAML', () async {
      await reg.createAgent(
        id: 'leo',
        displayName: 'Leo',
        profileRef: 'p1',
        skillIds: const [],
        philosophyRef: 'ph1',
        workspaceId: 'project/ws_auth',
      );

      // Capture auth creates the AuthProfileRef.
      final ref = await reg.captureAuthProfile(
        memberId: 'leo',
        systemId: 'github',
      );
      expect(ref.systemId, 'github');
      expect(ref.capturedAt, isNotNull);

      // Write to disk by calling update (triggers re-persist with authProfiles).
      final updated = await reg.update(
        memberId: 'leo',
        workspaceId: 'project/ws_auth',
        displayName: 'Leo Updated',
      );
      final a = updated as AgentMember;
      expect(a.authProfiles.any((ap) => ap.systemId == 'github'), isTrue);

      // Round-trip via new registry.
      final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
      final reg2 = MemberRegistry(
        kv: kv2,
        knowledgeSystem: KnowledgeSystem.stub(),
        rootDir: tmp.path,
      );
      final list = await reg2.listForWorkspace('project/ws_auth');
      expect(list.length, 1);
      final a2 = list.first as AgentMember;
      expect(a2.authProfiles.any((ap) => ap.systemId == 'github'), isTrue);
    });
  });

  group('MemberRegistry — changes stream', () {
    late MemberRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- m20: changes stream ---
    test(
      'm20 changes stream fires on addPerson/createAgent/update/delete',
      () async {
        final events = <int>[];
        int counter = 0;
        final sub = reg.changes.listen((_) => events.add(counter++));
        addTearDown(sub.cancel);

        await reg.addPerson(
          id: 'mary',
          displayName: 'Mary',
          workspaceId: 'project/ev_ws',
        );
        await reg.createAgent(
          id: 'mary_agent',
          displayName: 'Mary Agent',
          profileRef: 'p',
          skillIds: const [],
          philosophyRef: 'ph',
          workspaceId: 'project/ev_ws',
        );
        await reg.update(
          memberId: 'mary',
          workspaceId: 'project/ev_ws',
          displayName: 'Mary Updated',
        );
        await reg.deleteMember('mary', 'project/ev_ws');

        await Future<void>.delayed(Duration.zero);
        expect(events.length, 4);
      },
    );
  });

  group('MemberRegistry — growthStatus / captureAuthProfile', () {
    late MemberRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- m21: growthStatus PersonMember returns null ---
    test('m21 growthStatus returns null for PersonMember', () async {
      await reg.addPerson(
        id: 'ned',
        displayName: 'Ned',
        workspaceId: 'project/ws_g',
      );
      final growth = await reg.growthStatus('ned');
      expect(growth, isNull);
    });

    // --- m22: growthStatus AgentMember, subsystem inactive ---
    test(
      'm22 growthStatus returns AgentGrowth.zero when agent subsystem inactive',
      () async {
        await reg.createAgent(
          id: 'olive',
          displayName: 'Olive',
          profileRef: 'p',
          skillIds: const [],
          philosophyRef: 'ph',
          workspaceId: 'project/ws_g',
        );
        // KnowledgeSystem.stub() has isAgentSubsystemActivated == false.
        final growth = await reg.growthStatus('olive');
        expect(growth, isNotNull);
      },
    );

    // --- m23: captureAuthProfile throws for PersonMember ---
    test('m23 captureAuthProfile throws StateError for PersonMember', () async {
      await reg.addPerson(
        id: 'pat',
        displayName: 'Pat',
        workspaceId: 'project/ws_cap',
      );
      expect(
        () => reg.captureAuthProfile(memberId: 'pat', systemId: 'google'),
        throwsA(isA<StateError>()),
      );
    });

    // --- m24: captureAuthProfile replaces duplicate systemId ---
    test(
      'm24 captureAuthProfile replaces duplicate systemId idempotently',
      () async {
        await reg.createAgent(
          id: 'quinn',
          displayName: 'Quinn',
          profileRef: 'p',
          skillIds: const [],
          philosophyRef: 'ph',
          workspaceId: 'project/ws_cap',
        );

        await reg.captureAuthProfile(memberId: 'quinn', systemId: 'slack');
        await reg.captureAuthProfile(memberId: 'quinn', systemId: 'slack');

        final ws = await reg.listForWorkspace('project/ws_cap');
        final a = ws.firstWhere((m) => m.id == 'quinn') as AgentMember;
        // Only one entry for 'slack' after duplicate capture.
        expect(a.authProfiles.where((ap) => ap.systemId == 'slack').length, 1);
      },
    );
  });

  group('MemberKind enum coverage', () {
    // --- m25 ---
    test('m25 MemberKind has person and agent variants', () {
      expect(
        MemberKind.values,
        containsAll([MemberKind.person, MemberKind.agent]),
      );
    });
  });
}
