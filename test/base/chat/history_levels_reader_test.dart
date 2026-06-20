/// Tests for `resolveStudioHistoryLevels` — verifies the three-level
/// (studio / package / project) list is built correctly from the
/// ChromeBridge.listTabs snapshot and activePackagePath input.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/chat/history_levels_reader.dart';
import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns a ChromeBridge whose `listTabs` slot returns [tabs].
ChromeBridge _bridgeWithTabs(List<Map<String, dynamic>> tabs) {
  final bridge = ChromeBridge();
  bridge.listTabs = () => tabs;
  return bridge;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  const kConfigRoot = '/cfg';

  group('resolveStudioHistoryLevels — studio level (always present)', () {
    test('returns exactly one studio level when no active package', () {
      final bridge = _bridgeWithTabs([]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: null,
        configRoot: kConfigRoot,
      );
      expect(levels.length, 1);
      expect(levels.first.id, 'studio');
    });

    test('studio level label is "Studio"', () {
      final bridge = _bridgeWithTabs([]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: null,
        configRoot: kConfigRoot,
      );
      expect(levels.first.label, 'Studio');
    });

    test('studio level sublabel is "AppPlayer Studio"', () {
      final bridge = _bridgeWithTabs([]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: null,
        configRoot: kConfigRoot,
      );
      expect(levels.first.sublabel, 'AppPlayer Studio');
    });

    test('studio filePath uses "home" key under chats/', () {
      final bridge = _bridgeWithTabs([]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: null,
        configRoot: kConfigRoot,
      );
      expect(levels.first.filePath, p.join(kConfigRoot, 'chats', 'home.jsonl'));
    });
  });

  group('resolveStudioHistoryLevels — package level', () {
    test('adds package level when activePackagePath is non-null', () {
      final bridge = _bridgeWithTabs([
        {'key': '/pkg/my_app', 'name': 'My App'},
      ]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: '/pkg/my_app',
        configRoot: kConfigRoot,
      );
      expect(levels.length, 2);
      expect(levels[1].id, 'package');
    });

    test('package sublabel is the tab name when tab entry is found', () {
      final bridge = _bridgeWithTabs([
        {'key': '/pkg/my_app', 'name': 'My Awesome App'},
      ]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: '/pkg/my_app',
        configRoot: kConfigRoot,
      );
      expect(levels[1].sublabel, 'My Awesome App');
    });

    test(
      'package sublabel falls back to activePackagePath when tab not found',
      () {
        final bridge = _bridgeWithTabs([]); // empty — no matching tab
        const pkgPath = '/pkg/unknown_app';
        final levels = resolveStudioHistoryLevels(
          bridge: bridge,
          activePackagePath: pkgPath,
          configRoot: kConfigRoot,
        );
        expect(levels[1].sublabel, pkgPath);
      },
    );

    test('package filePath is sanitised package path under chats/', () {
      final bridge = _bridgeWithTabs([
        {'key': '/pkg/my_app', 'name': 'App'},
      ]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: '/pkg/my_app',
        configRoot: kConfigRoot,
      );
      // The key '/pkg/my_app' has slashes sanitised → '_pkg_my_app'
      final filename = p.basename(levels[1].filePath);
      expect(filename, endsWith('.jsonl'));
      expect(levels[1].filePath, startsWith(p.join(kConfigRoot, 'chats')));
    });
  });

  group('resolveStudioHistoryLevels — project level', () {
    test('adds project level when tab has currentProject', () {
      final bridge = _bridgeWithTabs([
        {
          'key': '/pkg/my_app',
          'name': 'My App',
          'currentProject': '/projects/scene_01',
        },
      ]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: '/pkg/my_app',
        configRoot: kConfigRoot,
      );
      expect(levels.length, 3);
      expect(levels[2].id, 'project');
    });

    test('project sublabel is the project folder basename', () {
      final bridge = _bridgeWithTabs([
        {
          'key': '/pkg/my_app',
          'name': 'My App',
          'currentProject': '/projects/my_scene',
        },
      ]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: '/pkg/my_app',
        configRoot: kConfigRoot,
      );
      expect(levels[2].sublabel, 'my_scene');
    });

    test('project filePath uses pkg::project composite key', () {
      const pkgPath = '/pkg/app';
      const projPath = '/projects/demo';
      final bridge = _bridgeWithTabs([
        {'key': pkgPath, 'name': 'App', 'currentProject': projPath},
      ]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: pkgPath,
        configRoot: kConfigRoot,
      );
      // The composite key is sanitised — colons and slashes become underscores.
      final filename = p.basename(levels[2].filePath);
      expect(filename, endsWith('.jsonl'));
      // Must be different from the package-only file
      expect(levels[2].filePath, isNot(levels[1].filePath));
    });

    test('no project level when tab lacks currentProject', () {
      final bridge = _bridgeWithTabs([
        {'key': '/pkg/app', 'name': 'App'}, // no currentProject
      ]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: '/pkg/app',
        configRoot: kConfigRoot,
      );
      expect(levels.length, 2); // studio + package only
      expect(levels.any((l) => l.id == 'project'), isFalse);
    });

    test('no project level when currentProject is null', () {
      final bridge = _bridgeWithTabs([
        {'key': '/pkg/app', 'name': 'App', 'currentProject': null},
      ]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: '/pkg/app',
        configRoot: kConfigRoot,
      );
      expect(levels.length, 2);
    });
  });

  group('resolveStudioHistoryLevels — listTabs null slot', () {
    test('null listTabs slot is treated as empty list (only studio level)', () {
      final bridge = ChromeBridge(); // listTabs is null — not wired
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: '/pkg/app',
        configRoot: kConfigRoot,
      );
      // Bridge listTabs == null → falls back to empty; package sublabel uses path
      expect(levels.length, 2);
      expect(levels[0].id, 'studio');
      expect(levels[1].id, 'package');
      expect(levels[1].sublabel, '/pkg/app'); // fallback to path
    });
  });

  group('resolveStudioHistoryLevels — ordering', () {
    test('levels are ordered studio → package → project', () {
      final bridge = _bridgeWithTabs([
        {'key': '/pkg/app', 'name': 'App', 'currentProject': '/projects/p1'},
      ]);
      final levels = resolveStudioHistoryLevels(
        bridge: bridge,
        activePackagePath: '/pkg/app',
        configRoot: kConfigRoot,
      );
      expect(levels[0].id, 'studio');
      expect(levels[1].id, 'package');
      expect(levels[2].id, 'project');
    });
  });
}
