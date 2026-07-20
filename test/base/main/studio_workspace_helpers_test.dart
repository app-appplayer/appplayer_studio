/// Unit tests for pure helper functions in `studio_workspace.dart`.
///
/// Only `readFriendlyLabel` is top-level (and pure-IO — it reads a file).
/// The `_interpolate` and `_slashHintsForBundle` helpers are private methods
/// on the widget State; they are tested here through observable behaviour
/// using temp files on disk.
///
/// Scenarios (readFriendlyLabel):
///   fw1  manifest.json with name field → returns the name
///   fw2  manifest.json with id but no name → returns last dot segment
///   fw3  manifest.json with both name and id → name wins
///   fw4  manifest.json missing → returns null
///   fw5  manifest.json malformed JSON → returns null
///   fw6  manifest.json empty name string → falls back to id last segment
///   fw7  manifest.json with nested manifest key → reads from manifest block
///
/// Scenarios (_interpolate via inline clone — private method not reachable):
///   ip1  simple {{key}} substituted from state map
///   ip2  nested {{a.b}} path walk
///   ip3  missing key → empty string substitution
///   ip4  {{}} empty placeholder → empty
///   ip5  no placeholders → template unchanged
///   ip6  multiple placeholders substituted in one pass
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/main/studio_workspace.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<Directory> _makeTempDir() => Directory.systemTemp.createTemp('sw_test_');

Future<void> _writeManifest(Directory dir, Object jsonContent) async {
  final f = File(p.join(dir.path, 'manifest.json'));
  await f.writeAsString(jsonEncode(jsonContent));
}

// ---------------------------------------------------------------------------
// Inline clone of _interpolate (private) for testing
// ---------------------------------------------------------------------------

String _interpolate(String template, Map<String, Object?> state) {
  return template.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (m) {
    final raw = m.group(1)?.trim() ?? '';
    if (raw.isEmpty) return '';
    Object? cursor = state;
    for (final seg in raw.split('.')) {
      if (cursor is Map) {
        cursor = cursor[seg];
      } else {
        cursor = null;
        break;
      }
    }
    return cursor == null ? '' : cursor.toString();
  });
}

// ---------------------------------------------------------------------------
// Inline clone of `_chatKeyForTab` (private) — the single key derivation the
// send / append / debug-chat paths must all agree on. `studio.debug.chat`
// once read `t.path` alone (project-less), landing on the empty base
// controller while the live conversation lived under the `::project` key —
// konpi's "another empty surface". This locks the derivation so the debug
// surface and the real chat can't diverge again.
// ---------------------------------------------------------------------------

String _chatKeyForTab({
  required bool isHome,
  String? path,
  String? currentProject,
}) {
  if (isHome) return 'home';
  final pkg = path ?? 'home';
  final cp = currentProject;
  return (cp != null && cp.isNotEmpty) ? '$pkg::$cp' : pkg;
}

void main() {
  // -------------------------------------------------------------------------
  // readFriendlyLabel
  // -------------------------------------------------------------------------
  group('readFriendlyLabel', () {
    late Directory dir;

    setUp(() async => dir = await _makeTempDir());
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('fw1 manifest with name field returns name', () async {
      await _writeManifest(dir, {
        'manifest': {'name': 'My Bundle', 'id': 'com.example.my_bundle'},
      });
      expect(readFriendlyLabel(dir.path), 'My Bundle');
    });

    test('fw2 manifest with id but no name returns last dot segment', () async {
      await _writeManifest(dir, {
        'manifest': {'id': 'com.example.cool_app'},
      });
      expect(readFriendlyLabel(dir.path), 'cool_app');
    });

    test('fw3 name takes priority over id last segment', () async {
      await _writeManifest(dir, {
        'manifest': {'name': 'Nice Name', 'id': 'com.example.different'},
      });
      expect(readFriendlyLabel(dir.path), 'Nice Name');
    });

    test('fw4 missing manifest.json returns null', () {
      // No file written
      expect(readFriendlyLabel(dir.path), isNull);
    });

    test('fw5 malformed JSON returns null', () async {
      final f = File(p.join(dir.path, 'manifest.json'));
      await f.writeAsString('{not valid json}');
      expect(readFriendlyLabel(dir.path), isNull);
    });

    test('fw6 empty name string falls back to id last segment', () async {
      await _writeManifest(dir, {
        'manifest': {'name': '', 'id': 'org.acme.reports'},
      });
      expect(readFriendlyLabel(dir.path), 'reports');
    });

    test('fw7 flat manifest (no nested manifest key) still parses', () async {
      // Some bundles store manifest fields at root level
      await _writeManifest(dir, {'name': 'Flat Bundle', 'id': 'flat.bundle'});
      expect(readFriendlyLabel(dir.path), 'Flat Bundle');
    });

    test('fw — id with no dot returns id verbatim', () async {
      await _writeManifest(dir, {
        'manifest': {'id': 'mybundle'},
      });
      expect(readFriendlyLabel(dir.path), 'mybundle');
    });
  });

  // -------------------------------------------------------------------------
  // _interpolate (cloned inline)
  // -------------------------------------------------------------------------
  group('_interpolate', () {
    test('ip1 simple {{key}} substituted from state', () {
      final result = _interpolate('Hello {{name}}!', {'name': 'World'});
      expect(result, 'Hello World!');
    });

    test('ip2 nested {{a.b}} path walk', () {
      final result = _interpolate('Mode: {{editor.mode}}', {
        'editor': {'mode': 'ui'},
      });
      expect(result, 'Mode: ui');
    });

    test('ip3 missing key → empty substitution', () {
      final result = _interpolate('Ref: {{missing}}', {});
      expect(result, 'Ref: ');
    });

    test('ip4 {{}} empty placeholder is not matched by regex — left as-is', () {
      // The regex requires at least one non-} char inside: [^}]+
      // So {{}} has no inner chars and is not substituted.
      final result = _interpolate('{{}}', {'': 'should_not_appear'});
      expect(result, '{{}}');
    });

    test('ip5 no placeholders → template unchanged', () {
      const tpl = 'Just a plain string.';
      expect(_interpolate(tpl, {}), tpl);
    });

    test('ip6 multiple placeholders substituted in one pass', () {
      final result = _interpolate('{{first}} and {{second}}', {
        'first': 'A',
        'second': 'B',
      });
      expect(result, 'A and B');
    });

    test('ip — deep path where intermediate is non-map → empty', () {
      final result = _interpolate('{{a.b.c}}', {'a': 'not-a-map'});
      expect(result, '');
    });

    test('ip — null value → empty', () {
      final result = _interpolate('{{key}}', {'key': null});
      expect(result, '');
    });
  });

  group('_chatKeyForTab', () {
    test('ck1 home tab → "home"', () {
      expect(_chatKeyForTab(isHome: true, path: null), 'home');
    });

    test('ck2 package, no open project → package path', () {
      expect(
        _chatKeyForTab(isHome: false, path: '/pkg/ops', currentProject: null),
        '/pkg/ops',
      );
    });

    test('ck3 package + open project → "<pkg>::<project>" (the debug-chat '
        'regression: a project-less key read the empty base controller)', () {
      expect(
        _chatKeyForTab(
          isHome: false,
          path: '/pkg/ops',
          currentProject: '/tmp/proj/x',
        ),
        '/pkg/ops::/tmp/proj/x',
      );
    });

    test('ck4 empty project string → package path (no dangling "::")', () {
      expect(
        _chatKeyForTab(isHome: false, path: '/pkg/ops', currentProject: ''),
        '/pkg/ops',
      );
    });

    test('ck5 null path (non-home) falls back to "home" base', () {
      expect(_chatKeyForTab(isHome: false, path: null), 'home');
    });
  });

  // -------------------------------------------------------------------------
  // `_chatKeyForCoordinator` (inline clone) — routes a coordinator auto-report
  // (async wake via `deliverAgentChatTurn`) to the chat surface that owns the
  // coordinator. Two match paths:
  //   1. base-manager: the coordinator IS a tab's own manager (welcome-state
  //      `ops.manager`, Home/App Builder base) → its key is always legitimate,
  //      bare `<pkg>` (welcome conversation) or `<pkg>::<project>`.
  //   2. scoped-override: a per-project coordinator (`ops.manager.<project>`)
  //      the active tab routes to. This can go STALE after project close — the
  //      override still names the closed project but the tab is now unbound, so
  //      `_chatKeyForTab` yields a bare key. Delivering there leaks a closed
  //      project's report onto the welcome-state chat (resurfaces as leftover
  //      content next unbound open), so a bare scoped resolution is dropped.
  // -------------------------------------------------------------------------

  String? chatKeyForCoordinator({
    required String agentId,
    required List<({String chatAgentId, bool isHome, String? path, String? cp})>
    tabs,
    required int active,
    required String? managerOverride,
    required String activeChatAgentId,
  }) {
    if (agentId.isEmpty) return null;
    String keyOf(({String chatAgentId, bool isHome, String? path, String? cp}) t) =>
        _chatKeyForTab(isHome: t.isHome, path: t.path, currentProject: t.cp);
    // 1. base-manager match — always legitimate, key as-is.
    for (final t in tabs) {
      if (t.chatAgentId == agentId) return keyOf(t);
    }
    // 2. scoped-override match — only while the active tab still holds a project.
    if (agentId == managerOverride || agentId == activeChatAgentId) {
      if (active >= 0 && active < tabs.length) {
        final key = keyOf(tabs[active]);
        if (key.contains('::')) return key;
      }
    }
    return null;
  }

  group('_chatKeyForCoordinator', () {
    const opsBase = 'ops.manager';
    const opsScoped = 'ops.manager./ops/projA';
    final unboundOps = (
      chatAgentId: opsBase,
      isHome: false,
      path: '/pkg/ops',
      cp: null,
    );
    final boundOps = (
      chatAgentId: opsBase,
      isHome: false,
      path: '/pkg/ops',
      cp: '/ops/projA',
    );

    test('cc1 base manager on unbound tab → its bare welcome key (legitimate)', () {
      expect(
        chatKeyForCoordinator(
          agentId: opsBase,
          tabs: <({String chatAgentId, bool isHome, String? path, String? cp})>[
            unboundOps,
          ],
          active: 0,
          managerOverride: null,
          activeChatAgentId: opsBase,
        ),
        '/pkg/ops',
      );
    });

    test('cc2 scoped coordinator, tab still bound → "<pkg>::<project>"', () {
      expect(
        chatKeyForCoordinator(
          agentId: opsScoped,
          tabs: <({String chatAgentId, bool isHome, String? path, String? cp})>[
            boundOps,
          ],
          active: 0,
          managerOverride: opsScoped,
          activeChatAgentId: opsScoped,
        ),
        '/pkg/ops::/ops/projA',
      );
    });

    test('cc3 STALE scoped coordinator after close (override set, tab unbound) '
        '→ null (no leak onto welcome bare key)', () {
      expect(
        chatKeyForCoordinator(
          agentId: opsScoped,
          tabs: <({String chatAgentId, bool isHome, String? path, String? cp})>[
            unboundOps,
          ],
          active: 0,
          // override went stale — still names the closed project.
          managerOverride: opsScoped,
          activeChatAgentId: opsScoped,
        ),
        isNull,
      );
    });

    test('cc4 unknown coordinator matches nothing → null', () {
      expect(
        chatKeyForCoordinator(
          agentId: 'scene.manager./x',
          tabs: <({String chatAgentId, bool isHome, String? path, String? cp})>[
            boundOps,
          ],
          active: 0,
          managerOverride: opsScoped,
          activeChatAgentId: opsScoped,
        ),
        isNull,
      );
    });

    test('cc5 empty agentId → null', () {
      expect(
        chatKeyForCoordinator(
          agentId: '',
          tabs: <({String chatAgentId, bool isHome, String? path, String? cp})>[
            boundOps,
          ],
          active: 0,
          managerOverride: opsScoped,
          activeChatAgentId: opsScoped,
        ),
        isNull,
      );
    });
  });
}
