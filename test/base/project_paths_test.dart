/// ProjectPaths — project-portable file reference normalisation + resolution.
library;

import 'package:appplayer_studio/src/base/infra/project_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = '/Users/x/ops/makemind_ops';
  const moved = '/private/tmp/scratch/mo_copy';

  group('toRelative', () {
    test('absolute inside project → project-relative', () {
      expect(
        ProjectPaths.toRelative(root, '$root/org_devmag.mbd/knowledge/a.md'),
        'org_devmag.mbd/knowledge/a.md',
      );
    });

    test('already-relative kept as-is (normalised)', () {
      expect(
        ProjectPaths.toRelative(root, 'org_devmag.mbd/knowledge/a.md'),
        'org_devmag.mbd/knowledge/a.md',
      );
    });

    test('absolute OUTSIDE project left unchanged (external ref)', () {
      expect(
        ProjectPaths.toRelative(root, '/Users/x/content/sample/s.md'),
        '/Users/x/content/sample/s.md',
      );
    });

    test('http URL left unchanged', () {
      expect(
        ProjectPaths.toRelative(root, 'https://makemind.dev/x'),
        'https://makemind.dev/x',
      );
    });
  });

  group('resolve', () {
    test('relative ref rebinds to the CURRENT project root (portable)', () {
      const rel = 'org_devmag.mbd/knowledge/a.md';
      expect(ProjectPaths.resolve(root, rel), '$root/$rel');
      // Same stored ref, project moved → resolves under the new location.
      expect(ProjectPaths.resolve(moved, rel), '$moved/$rel');
    });

    test('absolute stored ref returned unchanged', () {
      expect(
        ProjectPaths.resolve(root, '/etc/hosts'),
        '/etc/hosts',
      );
    });

    test('http URL returned unchanged', () {
      expect(
        ProjectPaths.resolve(root, 'https://x/y'),
        'https://x/y',
      );
    });
  });

  group('round-trip portability', () {
    test('store relative under A, resolve under B = follows the folder', () {
      final abs = '$root/org_devteam.mbd/skills/recruit.yaml';
      final stored = ProjectPaths.toRelative(root, abs); // at save time
      final reopened = ProjectPaths.resolve(moved, stored); // after move
      expect(stored, 'org_devteam.mbd/skills/recruit.yaml');
      expect(reopened, '$moved/org_devteam.mbd/skills/recruit.yaml');
    });
  });

  group('isInside', () {
    test('true for a path under root, false for a sibling', () {
      expect(ProjectPaths.isInside(root, '$root/a/b.md'), isTrue);
      expect(ProjectPaths.isInside(root, '/Users/x/other/b.md'), isFalse);
    });
  });
}
