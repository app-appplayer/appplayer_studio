/// [resolveWorkspaceId] + [WorkspaceExecutionContext] — the seam that removes
/// the global-active dependency from ops tool workspace resolution.
///
/// Verifies the three-layer precedence (explicit arg → execution-scoped →
/// global active) and that concurrent executions carry independent pinned
/// workspaces (the multi-agent race the "active workspace" inquiry reported).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/init/workspace_context.dart';

void main() {
  group('resolveWorkspaceId precedence', () {
    test('explicit workspaceId wins over exec + active', () {
      expect(
        resolveWorkspaceId(
          {'workspaceId': 'org/media'},
          execWorkspaceId: 'org/planning',
          activeWorkspaceId: 'org/makemind',
        ),
        'org/media',
      );
    });

    test('legacy `workspace` arg is honoured as explicit', () {
      expect(
        resolveWorkspaceId(
          {'workspace': 'org/media'},
          execWorkspaceId: 'org/planning',
          activeWorkspaceId: 'org/makemind',
        ),
        'org/media',
      );
    });

    test('exec-scoped wins over active when no explicit arg', () {
      expect(
        resolveWorkspaceId(
          const {},
          execWorkspaceId: 'org/planning',
          activeWorkspaceId: 'org/makemind',
        ),
        'org/planning',
      );
    });

    test('active is used only as the last-resort fallback', () {
      expect(
        resolveWorkspaceId(const {}, activeWorkspaceId: 'org/makemind'),
        'org/makemind',
      );
    });

    test('empty strings are ignored at each layer', () {
      expect(
        resolveWorkspaceId(
          {'workspaceId': ''},
          execWorkspaceId: '',
          activeWorkspaceId: 'org/makemind',
        ),
        'org/makemind',
      );
    });

    test('null when no source yields a workspace', () {
      expect(resolveWorkspaceId(const {}), isNull);
    });
  });

  group('WorkspaceExecutionContext', () {
    test('current is null outside any run scope', () {
      expect(WorkspaceExecutionContext.current, isNull);
    });

    test('run pins current for its subtree, then restores', () async {
      expect(WorkspaceExecutionContext.current, isNull);
      final inside = await WorkspaceExecutionContext.run('org/media', () async {
        await Future<void>.delayed(Duration.zero);
        return WorkspaceExecutionContext.current;
      });
      expect(inside, 'org/media');
      expect(WorkspaceExecutionContext.current, isNull);
    });

    test('nested run shadows the outer pin for the inner subtree', () async {
      final trace = await WorkspaceExecutionContext.run('org/outer', () async {
        final before = WorkspaceExecutionContext.current;
        final innner = await WorkspaceExecutionContext.run(
          'org/inner',
          () async => WorkspaceExecutionContext.current,
        );
        final after = WorkspaceExecutionContext.current;
        return [before, innner, after];
      });
      expect(trace, ['org/outer', 'org/inner', 'org/outer']);
    });

    test('null/empty workspaceId runs transparently (no pin)', () async {
      final v = await WorkspaceExecutionContext.run(
        null,
        () async => WorkspaceExecutionContext.current,
      );
      expect(v, isNull);
    });

    test(
      'concurrent executions keep independent pins (no cross-clobber)',
      () async {
        // Two agents run interleaved; each must observe only its own pin even
        // as the other switches — the exact race global active caused.
        final results = await Future.wait<String?>([
          WorkspaceExecutionContext.run('org/agent-a', () async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return WorkspaceExecutionContext.current;
          }),
          WorkspaceExecutionContext.run('org/agent-b', () async {
            await Future<void>.delayed(const Duration(milliseconds: 2));
            return WorkspaceExecutionContext.current;
          }),
        ]);
        expect(results, ['org/agent-a', 'org/agent-b']);
      },
    );
  });
}
