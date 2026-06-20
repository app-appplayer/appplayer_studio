/// Workspace model — unit tests for branches not covered in workspace_registry_test.
///
/// Pure: no I/O, no registry, no KV.
///
/// Scenarios:
///   wm1  fromYaml members as plain strings (not {id:} maps)
///   wm2  fromYaml members list mixing {id:} maps and plain strings
///   wm3  fromYaml unknown type string falls back to WorkspaceType.project
///   wm4  fromYaml missing createdAt falls back to DateTime.now() (non-null)
///   wm5  toYamlMap members serialised as [{id: '...'}] maps
///   wm6  WorkspaceType enum coverage: org / personal / project
///   wm7  fromYaml sharedWith list preserved
///   wm8  WorkspaceRegistry.systemWorkspaceId constant
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';

void main() {
  group('Workspace.fromYaml — edge cases', () {
    // wm1
    test('wm1 members as plain strings are parsed correctly', () {
      final ws = Workspace.fromYaml({
        'id': 'org/test',
        'members': ['alice', 'bob'],
      });
      expect(ws.members, containsAll(['alice', 'bob']));
    });

    // wm2
    test('wm2 members list mixing map and string forms', () {
      final ws = Workspace.fromYaml({
        'id': 'org/mix',
        'members': [
          {'id': 'agent_1'},
          'person_2',
          {'id': 'agent_3'},
        ],
      });
      expect(ws.members, containsAll(['agent_1', 'person_2', 'agent_3']));
      expect(ws.members, hasLength(3));
    });

    // wm3
    test('wm3 unknown type string falls back to WorkspaceType.project', () {
      final ws = Workspace.fromYaml({
        'id': 'unk/ws',
        'type': 'enterprise', // not a valid enum name
      });
      expect(ws.type, WorkspaceType.project);
    });

    // wm4
    test(
      'wm4 missing createdAt does not throw; result is non-null DateTime',
      () {
        final ws = Workspace.fromYaml({'id': 'org/nodate'});
        expect(ws.createdAt, isA<DateTime>());
      },
    );

    test('wm4b invalid createdAt string falls back to DateTime.now()', () {
      final ws = Workspace.fromYaml({
        'id': 'org/baddate',
        'createdAt': 'not-a-date',
      });
      expect(ws.createdAt, isA<DateTime>());
    });

    // wm5
    test('wm5 toYamlMap serialises members as [{id: ...}] maps', () {
      final ws = Workspace(
        id: 'org/serial',
        type: WorkspaceType.org,
        title: 'Serial',
        locale: 'en',
        timezone: 'UTC',
        createdAt: DateTime.utc(2026, 1, 1),
        members: const ['alice', 'bob'],
      );
      final map = ws.toYamlMap();
      final members = map['members'] as List;
      expect(members, hasLength(2));
      expect(members[0], {'id': 'alice'});
      expect(members[1], {'id': 'bob'});
    });

    // wm6
    test('wm6 WorkspaceType enum: org / personal / project', () {
      expect(WorkspaceType.org.name, 'org');
      expect(WorkspaceType.personal.name, 'personal');
      expect(WorkspaceType.project.name, 'project');
      expect(WorkspaceType.values, hasLength(3));
    });

    // wm7
    test('wm7 fromYaml sharedWith list preserved', () {
      final ws = Workspace.fromYaml({
        'id': 'org/shared',
        'sharedWith': ['team_a', 'team_b'],
      });
      expect(ws.sharedWith, containsAll(['team_a', 'team_b']));
    });

    test('wm7b fromYaml sharedWith defaults to empty when missing', () {
      final ws = Workspace.fromYaml({'id': 'org/noshare'});
      expect(ws.sharedWith, isEmpty);
    });

    // wm8
    test('wm8 WorkspaceRegistry.systemWorkspaceId is _system', () {
      expect(WorkspaceRegistry.systemWorkspaceId, '_system');
    });

    test('wm — title defaults to id when title missing', () {
      final ws = Workspace.fromYaml({'id': 'org/notitle'});
      expect(ws.title, 'org/notitle');
    });

    test('wm — locale defaults to ko when missing', () {
      final ws = Workspace.fromYaml({'id': 'org/noloc'});
      expect(ws.locale, 'ko');
    });

    test('wm — timezone defaults to Asia/Seoul when missing', () {
      final ws = Workspace.fromYaml({'id': 'org/notz'});
      expect(ws.timezone, 'Asia/Seoul');
    });

    test('wm — tags map preserved through fromYaml', () {
      final ws = Workspace.fromYaml({
        'id': 'org/tagged',
        'tags': {'env': 'prod', 'region': 'us-east'},
      });
      expect(ws.tags['env'], 'prod');
      expect(ws.tags['region'], 'us-east');
    });

    test('wm — tags keys/values are coerced to String', () {
      // YAML can give int keys in Dart.
      final ws = Workspace.fromYaml({
        'id': 'org/intkeys',
        'tags': {1: 'one', 'key': 2},
      });
      expect(ws.tags['1'], 'one');
      expect(ws.tags['key'], '2');
    });
  });
}
