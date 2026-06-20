/// Unit tests for [BuildToolsDispatcher] and [BuildToolResult].
///
/// Coverage strategy:
/// All tests exercise real in-process logic. VibeProject is constructed with
/// a minimal fake canonical so the constructor does not crash. Pipeline is
/// left null unless a test specifically needs it (dryRun paths), in which
/// case a _FakePipeline is used.
///
/// Private static methods (_normalizePath, _resolvePath, _inferLayer, etc.)
/// are tested indirectly via the public methods that call them and expose
/// observable results. No reflective access to private members is attempted.
///
/// Scenario index:
///
/// --- BuildToolResult ---
/// r1  success — fields and toJson
/// r2  failure — success=false, no path/payload
/// r3  failure — with path
/// r4  toJson omits null fields
///
/// --- readBuildGuide (smoke + _truncate exercise via long payloads) ---
/// r5  readBuildGuide returns success with pattern guide
///
/// --- bundleOutline ---
/// r6  canonical not wired → failure "not wired"
/// r7  empty root → success, empty payload
/// r8  manifest fields surfaced
/// r9  pages listed with id and path
/// r10 templates listed with id and path
///
/// --- getSection ---
/// r11 unknown section → failure "unknown section"
/// r12 manifest section resolves
/// r13 pages section with id resolves single page
/// r14 app section strips heavy keys
///
/// --- treeOutline (exercises _normalizePath, _resolvePath, _walkWidgets) ---
/// r15 canonical not wired → failure
/// r16 full tree returned for null scope
/// r17 scoped to a page → only that subtree
/// r18 bad scope path → failure
///
/// --- getWidget (exercises _resolvePath, _label) ---
/// r19 canonical not wired → failure
/// r20 widget found → success with payload
/// r21 widget not found → failure
/// r22 non-map node → failure
///
/// --- checkWiring ---
/// r23 canonical not wired → failure
/// r24 orphan page detected
/// r25 missing route target detected
/// r26 clean wiring → 0 issues
///
/// --- findWidgets (exercises _refersInOwnProps, _walkWidgets) ---
/// r27 canonical not wired → failure
/// r28 no filters → failure
/// r29 type filter
/// r30 hasProp filter
/// r31 refersTo filter
/// r32 label filter
///
/// --- applyThemePreset ---
/// r33 invalid seedColor
/// r34 invalid mode
/// r35 valid + no pipeline → failure
///
/// --- applyLayoutPreset ---
/// r36 not wired → failure
/// r37 unknown kind
/// r38 dryRun hero
/// r39 dryRun form
/// r40 dryRun cardList
/// r41 dryRun settings
///
/// --- applyRecipe ---
/// r42 canonical not wired
/// r43 unknown recipe
/// r44 dryRun wrap_with_card
///
/// --- renamePage / renameTemplate / renameStateKey ---
/// r45 renamePage same id
/// r46 renamePage empty oldId
/// r47 renameTemplate empty ids
/// r48 renameStateKey invalid scope
///
/// --- widgetShapeAudit ---
/// r49 canonical not wired
/// r50 button without label/icon
/// r51 text without content
/// r52 image without src
/// r53 onTap as List
///
/// --- widgetLint ---
/// r54 empty_container
/// r55 redundant_wrapper
///
/// --- tokenizationAudit ---
/// r56 hardcoded hex color
/// r57 spacing value
///
/// --- routeAudit ---
/// r58 canonical not wired
/// r59 orphan + missing initial route
///
/// --- search ---
/// r60 canonical not wired
/// r61 empty query
/// r62 page id match
///
/// --- themePresetSet ---
/// r63 invalid preset
/// r64 valid + no pipeline
///
/// --- i18nLocaleAdd ---
/// r65 invalid BCP-47
/// r66 already registered
///
/// --- i18nLocaleRemove ---
/// r67 not registered
///
/// --- i18nTextDirectionSet ---
/// r68 invalid direction
///
/// --- navigationItemStyleSet ---
/// r69 negative index
///
/// --- serviceSet ---
/// r70 empty name
/// r71 invalid kind
///
/// --- extractToTemplate ---
/// r72 invalid template id
///
/// --- diffApply ---
/// r73 empty ops
/// r74 move op not supported
///
/// --- pageCreate ---
/// r75 canonical not wired
/// r76 route not starting with /
///
/// --- stateProposeForPage ---
/// r77 empty pageId
///
/// --- pendingDiff ---
/// r78 canonical not wired
///
/// --- widgetDiff ---
/// r79 canonical not wired
///
/// --- help ---
/// r80 returns all groups
///
/// --- specCard ---
/// r81 unknown topic
/// r82 known topic
///
/// --- dispatch ---
/// r83 unknown tool → null
/// r84 read_build_guide routes correctly
/// r85 add_child without widget.type
///
/// --- getBuildConfig ---
/// r86 no preset → success
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart'
    show
        CanonicalPatch,
        ImportKind,
        LayerId,
        PatchPipeline,
        UndoState,
        WorkspaceCanonical;
import 'package:appplayer_studio/builtin_api.dart'
    show CanonicalChange, CanonicalChangeKind, PatchApplied, PatchResult;
import 'package:mcp_bundle/mcp_bundle.dart' show McpBundle;
import 'package:appplayer_studio/src/apps/app_builder/core/vibe_project.dart';
import 'package:appplayer_studio/src/apps/app_builder/feat/build_tools.dart';

// ── Fake WorkspaceCanonical ──────────────────────────────────────────────────

class _FakeCanonical implements WorkspaceCanonical {
  _FakeCanonical([Map<String, dynamic>? json])
    : _json = json ?? const <String, dynamic>{};

  Map<String, dynamic> _json;

  final _changesCtrl = StreamController<CanonicalChange>.broadcast();
  final _undoCtrl = StreamController<UndoState>.broadcast();

  @override
  Map<String, dynamic> get currentJson => _json;

  @override
  String? get workspacePath => null;

  @override
  Stream<CanonicalChange> get changes => _changesCtrl.stream;

  @override
  Stream<UndoState> get undoStateChanges => _undoCtrl.stream;

  @override
  Stream<bool> get dirtyChanges => const Stream<bool>.empty();

  @override
  bool get canUndo => false;

  @override
  bool get canRedo => false;

  @override
  bool get isDirty => false;

  @override
  bool get hasRestoredDraft => false;

  @override
  McpBundle get current => throw UnimplementedError();

  @override
  String? get committedHash => null;

  @override
  List<Map<String, dynamic>> get undoStackJson => const [];

  @override
  List<Map<String, dynamic>> get redoStackJson => const [];

  @override
  Future<McpBundle> open(String workspacePath) => throw UnimplementedError();

  @override
  Future<McpBundle> import({
    required String source,
    required ImportKind kind,
  }) => throw UnimplementedError();

  @override
  Future<void> applyAtomic(CanonicalPatch patch) => throw UnimplementedError();

  @override
  Future<void> save() => throw UnimplementedError();

  @override
  Future<void> saveAs(String newPath) => throw UnimplementedError();

  @override
  Future<void> revert() => throw UnimplementedError();

  @override
  Future<bool> undo() => throw UnimplementedError();

  @override
  Future<bool> redo() => throw UnimplementedError();

  @override
  Future<String> hash() => throw UnimplementedError();

  @override
  void seedUndoStacks({
    required List<Map<String, dynamic>> undo,
    required List<Map<String, dynamic>> redo,
  }) {}
}

// ── Fake PatchPipeline — returns success for every call ─────────────────────

class _FakePipeline implements PatchPipeline {
  @override
  Future<PatchResult> apply(CanonicalPatch patch) async => const PatchApplied(
    changedPointers: <String>[],
    beforeHash: '',
    afterHash: '',
  );
}

// ── Helpers ──────────────────────────────────────────────────────────────────

VibeProject _makeProject(String projectPath, _FakeCanonical canonical) {
  final meta = ProjectMeta(
    name: 'test',
    createdAt: DateTime(2024),
    lastOpenedAt: DateTime(2024),
    channels: <String, ChannelDef>{
      'serving': ChannelDef(subdir: 'bundles/serving.mbd'),
    },
    activeChannel: 'serving',
  );
  return VibeProject(
    projectPath: projectPath,
    canonical: canonical,
    meta: meta,
    chatLog: null,
    historyLog: null,
    undoSidecar: null,
  );
}

BuildToolsDispatcher _makeDispatcher({
  Map<String, dynamic>? json,
  _FakePipeline? pipeline,
  String? projectPath,
}) {
  final c = _FakeCanonical(json ?? const <String, dynamic>{});
  final p = _makeProject(projectPath ?? Directory.systemTemp.path, c);
  return BuildToolsDispatcher(project: p, canonical: c, pipeline: pipeline);
}

BuildToolsDispatcher _makeNoCanonical() {
  final c = _FakeCanonical(const <String, dynamic>{});
  final p = _makeProject(Directory.systemTemp.path, c);
  return BuildToolsDispatcher(project: p, canonical: null);
}

/// A minimal valid bundle with pages, routes, and a home page widget tree.
Map<String, dynamic> _valid() => <String, dynamic>{
  'manifest': <String, dynamic>{
    'name': 'My App',
    'version': '1.0.0',
    'description': 'A test app',
  },
  'ui': <String, dynamic>{
    'type': 'application',
    'initialRoute': '/home',
    'routes': <String, dynamic>{'home': '/home'},
    'pages': <String, dynamic>{
      'home': <String, dynamic>{
        'type': 'page',
        'title': 'Home',
        'content': <String, dynamic>{
          'type': 'linear',
          'direction': 'vertical',
          'children': <dynamic>[
            <String, dynamic>{'type': 'text', 'content': 'Hello'},
            <String, dynamic>{'type': 'button', 'label': 'Go'},
          ],
        },
      },
    },
    'templates': <String, dynamic>{},
  },
};

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── r1 ───────────────────────────────────────────────────────────────────
  test('r1: BuildToolResult.success populates fields and toJson', () {
    final r = BuildToolResult.success(
      message: 'ok',
      path: '/x',
      payload: '{"n":1}',
    );
    expect(r.success, isTrue);
    expect(r.message, 'ok');
    expect(r.path, '/x');
    expect(r.payload, '{"n":1}');
    final j = r.toJson();
    expect(j['ok'], isTrue);
    expect(j['message'], 'ok');
    expect(j['path'], '/x');
    expect(j['payload'], '{"n":1}');
  });

  // ── r2 ───────────────────────────────────────────────────────────────────
  test(
    'r2: BuildToolResult.failure has success=false with no path/payload',
    () {
      final r = BuildToolResult.failure('boom');
      expect(r.success, isFalse);
      expect(r.message, 'boom');
      expect(r.path, isNull);
      expect(r.payload, isNull);
      expect(r.toJson()['ok'], isFalse);
    },
  );

  // ── r3 ───────────────────────────────────────────────────────────────────
  test('r3: BuildToolResult.failure with path carries the path', () {
    final r = BuildToolResult.failure('not found', path: '/ui/pages/x');
    expect(r.path, '/ui/pages/x');
    expect(r.toJson()['path'], '/ui/pages/x');
  });

  // ── r4 ───────────────────────────────────────────────────────────────────
  test('r4: toJson does not emit path or payload keys when null', () {
    final j = BuildToolResult.success(message: 'minimal').toJson();
    expect(j.containsKey('path'), isFalse);
    expect(j.containsKey('payload'), isFalse);
  });

  // ── r5 ───────────────────────────────────────────────────────────────────
  test('r5: readBuildGuide returns success with non-empty payload', () async {
    final r = await _makeDispatcher().readBuildGuide();
    expect(r.success, isTrue);
    expect(r.payload, isNotNull);
    expect(r.payload!.length, greaterThan(200));
  });

  // ── r6 ───────────────────────────────────────────────────────────────────
  test('r6: bundleOutline fails when canonical not wired', () async {
    final r = await _makeNoCanonical().bundleOutline();
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('not wired'));
  });

  // ── r7 ───────────────────────────────────────────────────────────────────
  test(
    'r7: bundleOutline succeeds with empty payload for empty root',
    () async {
      final r =
          await _makeDispatcher(
            json: const <String, dynamic>{},
          ).bundleOutline();
      expect(r.success, isTrue);
      expect((jsonDecode(r.payload!) as Map<String, dynamic>).isEmpty, isTrue);
    },
  );

  // ── r8 ───────────────────────────────────────────────────────────────────
  test(
    'r8: bundleOutline surfaces manifest name, version, description',
    () async {
      final r = await _makeDispatcher(json: _valid()).bundleOutline();
      expect(r.success, isTrue);
      final manifest = (jsonDecode(r.payload!) as Map)['manifest'] as Map;
      expect(manifest['name'], equals('My App'));
      expect(manifest['version'], equals('1.0.0'));
      expect(manifest['description'], equals('A test app'));
    },
  );

  // ── r9 ───────────────────────────────────────────────────────────────────
  test('r9: bundleOutline lists pages with id and RFC-6901 path', () async {
    final r = await _makeDispatcher(json: _valid()).bundleOutline();
    final pages = (jsonDecode(r.payload!) as Map)['pages'] as List;
    expect(pages.length, equals(1));
    final home = pages[0] as Map;
    expect(home['id'], equals('home'));
    expect(home['path'], equals('/ui/pages/home'));
  });

  // ── r10 ──────────────────────────────────────────────────────────────────
  test('r10: bundleOutline lists templates with id and path', () async {
    final d = _makeDispatcher(
      json: <String, dynamic>{
        'ui': <String, dynamic>{
          'templates': <String, dynamic>{
            'card': <String, dynamic>{'type': 'template'},
          },
        },
      },
    );
    final r = await d.bundleOutline();
    final templates = (jsonDecode(r.payload!) as Map)['templates'] as List;
    expect(templates.length, equals(1));
    expect((templates[0] as Map)['id'], equals('card'));
    expect((templates[0] as Map)['path'], equals('/ui/templates/card'));
  });

  // ── r11 ──────────────────────────────────────────────────────────────────
  test('r11: getSection returns failure for unknown section', () async {
    final r = await _makeDispatcher().getSection(section: 'foobar');
    expect(r.success, isFalse);
    expect(r.message, contains('unknown section'));
  });

  // ── r12 ──────────────────────────────────────────────────────────────────
  test('r12: getSection resolves manifest section', () async {
    final r = await _makeDispatcher(
      json: _valid(),
    ).getSection(section: 'manifest');
    expect(r.success, isTrue);
    final payload = jsonDecode(r.payload!) as Map;
    expect(payload['section'], equals('manifest'));
    expect((payload['value'] as Map)['name'], equals('My App'));
  });

  // ── r13 ──────────────────────────────────────────────────────────────────
  test('r13: getSection with id resolves a single page', () async {
    final r = await _makeDispatcher(
      json: _valid(),
    ).getSection(section: 'pages', id: 'home');
    expect(r.success, isTrue);
    final payload = jsonDecode(r.payload!) as Map;
    expect(payload['id'], equals('home'));
    expect((payload['value'] as Map)['title'], equals('Home'));
  });

  // ── r14 ──────────────────────────────────────────────────────────────────
  test(
    'r14: getSection app strips pages, templates, theme, dashboard',
    () async {
      final d = _makeDispatcher(
        json: <String, dynamic>{
          'ui': <String, dynamic>{
            'type': 'application',
            'name': 'X',
            'version': '2.0',
            'pages': <String, dynamic>{},
            'templates': <String, dynamic>{},
            'theme': <String, dynamic>{},
            'dashboard': <String, dynamic>{},
          },
        },
      );
      final r = await d.getSection(section: 'app');
      expect(r.success, isTrue);
      final value = (jsonDecode(r.payload!) as Map)['value'] as Map;
      for (final k in ['pages', 'templates', 'theme', 'dashboard']) {
        expect(value.containsKey(k), isFalse, reason: '$k should be stripped');
      }
      expect(value['name'], equals('X'));
    },
  );

  // ── r15 ──────────────────────────────────────────────────────────────────
  test('r15: treeOutline fails when canonical not wired', () async {
    final r = await _makeNoCanonical().treeOutline();
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('not wired'));
  });

  // ── r16 ──────────────────────────────────────────────────────────────────
  test('r16: treeOutline returns widget entries for entire bundle', () async {
    final r = await _makeDispatcher(json: _valid()).treeOutline();
    expect(r.success, isTrue);
    final widgets = (jsonDecode(r.payload!) as Map)['widgets'] as List;
    final types = widgets.map((w) => (w as Map)['type']).toList();
    expect(types, contains('page'));
    expect(types, contains('linear'));
    expect(types, contains('text'));
    expect(types, contains('button'));
  });

  // ── r17 ──────────────────────────────────────────────────────────────────
  test('r17: treeOutline scoped to a page returns only that subtree', () async {
    final r = await _makeDispatcher(
      json: _valid(),
    ).treeOutline(scope: '/ui/pages/home');
    expect(r.success, isTrue);
    final widgets = (jsonDecode(r.payload!) as Map)['widgets'] as List;
    expect(widgets.isNotEmpty, isTrue);
    expect((widgets[0] as Map)['type'], equals('page'));
  });

  // ── r18 ──────────────────────────────────────────────────────────────────
  // treeOutline falls back to /ui when scope is invalid; getWidget returns
  // failure for path-traversal paths because _normalizePath returns null.
  test('r18: getWidget returns failure for path-traversal path', () async {
    final r = await _makeDispatcher(
      json: _valid(),
    ).getWidget(path: '/ui/../manifest');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('invalid path'));
  });

  // ── r19 ──────────────────────────────────────────────────────────────────
  test('r19: getWidget fails when canonical not wired', () async {
    final r = await _makeNoCanonical().getWidget(path: '/ui/pages/home');
    expect(r.success, isFalse);
  });

  // ── r20 ──────────────────────────────────────────────────────────────────
  test('r20: getWidget returns success with widget payload', () async {
    final r = await _makeDispatcher(
      json: _valid(),
    ).getWidget(path: '/ui/pages/home');
    expect(r.success, isTrue);
    final payload = jsonDecode(r.payload!) as Map;
    expect(payload['path'], equals('/ui/pages/home'));
    expect((payload['widget'] as Map)['type'], equals('page'));
  });

  // ── r21 ──────────────────────────────────────────────────────────────────
  test('r21: getWidget returns failure when path not found', () async {
    final r = await _makeDispatcher(
      json: _valid(),
    ).getWidget(path: '/ui/pages/ghost');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('not found'));
  });

  // ── r22 ──────────────────────────────────────────────────────────────────
  test(
    'r22: getWidget returns failure when resolved value is not a map',
    () async {
      final r = await _makeDispatcher(
        json: <String, dynamic>{
          'ui': <String, dynamic>{'initialRoute': '/home'},
        },
      ).getWidget(path: '/ui/initialRoute');
      expect(r.success, isFalse);
      expect(r.message.toLowerCase(), contains('not a widget'));
    },
  );

  // ── r23 ──────────────────────────────────────────────────────────────────
  test('r23: checkWiring fails when canonical not wired', () async {
    final r = await _makeNoCanonical().checkWiring();
    expect(r.success, isFalse);
  });

  // ── r24 ──────────────────────────────────────────────────────────────────
  test('r24: checkWiring detects orphan page with no route', () async {
    final d = _makeDispatcher(
      json: <String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'home': <String, dynamic>{},
            'orphan': <String, dynamic>{},
          },
          'routes': <String, dynamic>{'/home': 'home'},
        },
      },
    );
    final r = await d.checkWiring();
    expect(r.success, isTrue);
    final issues = (jsonDecode(r.payload!) as Map)['issues'] as List;
    final orphans = issues.where((i) => i['kind'] == 'orphan_page').toList();
    expect(orphans.length, equals(1));
    expect(orphans[0]['page'], equals('orphan'));
  });

  // ── r25 ──────────────────────────────────────────────────────────────────
  test(
    'r25: checkWiring detects route pointing to non-existent page',
    () async {
      final d = _makeDispatcher(
        json: <String, dynamic>{
          'ui': <String, dynamic>{
            'pages': <String, dynamic>{'home': <String, dynamic>{}},
            'routes': <String, dynamic>{'/home': 'home', '/ghost': 'ghost'},
          },
        },
      );
      final r = await d.checkWiring();
      expect(r.success, isTrue);
      final issues = (jsonDecode(r.payload!) as Map)['issues'] as List;
      final missing =
          issues.where((i) => i['kind'] == 'missing_route_target').toList();
      expect(missing.length, equals(1));
      expect(missing[0]['pageId'], equals('ghost'));
    },
  );

  // ── r26 ──────────────────────────────────────────────────────────────────
  test('r26: checkWiring returns 0 issues for clean bundle', () async {
    final d = _makeDispatcher(
      json: <String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{'home': <String, dynamic>{}},
          'routes': <String, dynamic>{'/home': 'home'},
        },
      },
    );
    final r = await d.checkWiring();
    expect(r.success, isTrue);
    expect((jsonDecode(r.payload!) as Map)['issues'], isEmpty);
  });

  // ── r27 ──────────────────────────────────────────────────────────────────
  test('r27: findWidgets fails when canonical not wired', () async {
    final r = await _makeNoCanonical().findWidgets(type: 'text');
    expect(r.success, isFalse);
  });

  // ── r28 ──────────────────────────────────────────────────────────────────
  test('r28: findWidgets requires at least one filter', () async {
    final r = await _makeDispatcher(json: _valid()).findWidgets();
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('at least one filter'));
  });

  // ── r29 ──────────────────────────────────────────────────────────────────
  test('r29: findWidgets by type returns only matching widgets', () async {
    final r = await _makeDispatcher(json: _valid()).findWidgets(type: 'text');
    expect(r.success, isTrue);
    final matches = (jsonDecode(r.payload!) as Map)['matches'] as List;
    expect(matches.length, equals(1));
    expect((matches[0] as Map)['type'], equals('text'));
  });

  // ── r30 ──────────────────────────────────────────────────────────────────
  test(
    'r30: findWidgets by hasProp returns widgets with that property',
    () async {
      final d = _makeDispatcher(
        json: <String, dynamic>{
          'ui': <String, dynamic>{
            'pages': <String, dynamic>{
              'p': <String, dynamic>{
                'type': 'page',
                'content': <String, dynamic>{
                  'type': 'linear',
                  'children': <dynamic>[
                    <String, dynamic>{'type': 'image', 'src': 'foo.png'},
                    <String, dynamic>{'type': 'text', 'content': 'hi'},
                  ],
                },
              },
            },
          },
        },
      );
      final r = await d.findWidgets(hasProp: 'src');
      expect(r.success, isTrue);
      final matches = (jsonDecode(r.payload!) as Map)['matches'] as List;
      expect(matches.length, equals(1));
      expect((matches[0] as Map)['type'], equals('image'));
    },
  );

  // ── r31 ──────────────────────────────────────────────────────────────────
  test(
    'r31: findWidgets by refersTo finds widgets whose own props contain needle',
    () async {
      final d = _makeDispatcher(
        json: <String, dynamic>{
          'ui': <String, dynamic>{
            'pages': <String, dynamic>{
              'p': <String, dynamic>{
                'type': 'page',
                'content': <String, dynamic>{
                  'type': 'linear',
                  'children': <dynamic>[
                    <String, dynamic>{
                      'type': 'text',
                      'content': '@{state.count}',
                    },
                    <String, dynamic>{'type': 'button', 'label': 'static'},
                  ],
                },
              },
            },
          },
        },
      );
      final r = await d.findWidgets(refersTo: 'state.count');
      expect(r.success, isTrue);
      final matches = (jsonDecode(r.payload!) as Map)['matches'] as List;
      expect(matches.length, equals(1));
      expect((matches[0] as Map)['type'], equals('text'));
    },
  );

  // ── r32 ──────────────────────────────────────────────────────────────────
  test('r32: findWidgets by label matches labeled widgets', () async {
    // _valid() has a button with label 'Go'
    final r = await _makeDispatcher(json: _valid()).findWidgets(label: 'Go');
    expect(r.success, isTrue);
    final matches = (jsonDecode(r.payload!) as Map)['matches'] as List;
    expect(matches.isNotEmpty, isTrue);
    expect((matches[0] as Map)['type'], equals('button'));
  });

  // ── r33 ──────────────────────────────────────────────────────────────────
  test('r33: applyThemePreset rejects invalid seedColor', () async {
    final r = await _makeDispatcher().applyThemePreset(seedColor: 'notacolor');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('seedcolor'));
  });

  // ── r34 ──────────────────────────────────────────────────────────────────
  test('r34: applyThemePreset rejects invalid mode', () async {
    final r = await _makeDispatcher().applyThemePreset(
      seedColor: '#FF5733',
      mode: 'rainbow',
    );
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('mode'));
  });

  // ── r35 ──────────────────────────────────────────────────────────────────
  test(
    'r35: applyThemePreset with valid args fails when pipeline not wired',
    () async {
      final r = await _makeDispatcher().applyThemePreset(seedColor: '#FF5733');
      expect(r.success, isFalse);
      expect(r.message.toLowerCase(), contains('pipeline'));
    },
  );

  // ── r36 ──────────────────────────────────────────────────────────────────
  test(
    'r36: applyLayoutPreset fails when canonical/pipeline not wired',
    () async {
      final r = await _makeNoCanonical().applyLayoutPreset(
        pageId: 'home',
        kind: 'hero',
      );
      expect(r.success, isFalse);
      expect(r.message.toLowerCase(), contains('not wired'));
    },
  );

  // ── r37 ──────────────────────────────────────────────────────────────────
  test('r37: applyLayoutPreset fails for unknown kind', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.applyLayoutPreset(pageId: 'home', kind: 'unknownKind');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('unknown kind'));
  });

  // ── r38 ──────────────────────────────────────────────────────────────────
  test(
    'r38: applyLayoutPreset dryRun hero returns hero content shape',
    () async {
      final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
      final r = await d.applyLayoutPreset(
        pageId: 'home',
        kind: 'hero',
        dryRun: true,
      );
      expect(r.success, isTrue);
      final payload = jsonDecode(r.payload!) as Map;
      expect(payload['kind'], equals('hero'));
      final children = (payload['content'] as Map)['children'] as List;
      expect(children.length, equals(3)); // displaySmall + bodyLarge + button
      expect((children[0] as Map)['type'], equals('text'));
      expect((children[2] as Map)['type'], equals('button'));
    },
  );

  // ── r39 ──────────────────────────────────────────────────────────────────
  test(
    'r39: applyLayoutPreset dryRun form seeds state.fields and state.errors',
    () async {
      final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
      final r = await d.applyLayoutPreset(
        pageId: 'home',
        kind: 'form',
        dryRun: true,
      );
      expect(r.success, isTrue);
      final state = (jsonDecode(r.payload!) as Map)['state'] as Map;
      expect(state.containsKey('fields'), isTrue);
      expect(state.containsKey('errors'), isTrue);
    },
  );

  // ── r40 ──────────────────────────────────────────────────────────────────
  test('r40: applyLayoutPreset dryRun cardList has 3 card children', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.applyLayoutPreset(
      pageId: 'home',
      kind: 'cardList',
      dryRun: true,
    );
    expect(r.success, isTrue);
    final children =
        ((jsonDecode(r.payload!) as Map)['content'] as Map)['children'] as List;
    expect(children.length, equals(3));
    for (final child in children) {
      expect((child as Map)['type'], equals('card'));
    }
  });

  // ── r41 ──────────────────────────────────────────────────────────────────
  test(
    'r41: applyLayoutPreset dryRun settings has 4 children (title+3 options)',
    () async {
      final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
      final r = await d.applyLayoutPreset(
        pageId: 'home',
        kind: 'settings',
        dryRun: true,
      );
      expect(r.success, isTrue);
      final children =
          ((jsonDecode(r.payload!) as Map)['content'] as Map)['children']
              as List;
      expect(children.length, equals(4));
    },
  );

  // ── r42 ──────────────────────────────────────────────────────────────────
  test('r42: applyRecipe fails when canonical not wired', () async {
    final r = await _makeNoCanonical().applyRecipe(
      name: 'wrap_with_card',
      args: <String, dynamic>{},
    );
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('not wired'));
  });

  // ── r43 ──────────────────────────────────────────────────────────────────
  test('r43: applyRecipe returns failure for unknown recipe', () async {
    final r = await _makeDispatcher(
      json: _valid(),
    ).applyRecipe(name: 'no_such_recipe', args: {});
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('unknown recipe'));
  });

  // ── r44 ──────────────────────────────────────────────────────────────────
  test(
    'r44: applyRecipe dryRun wrap_with_card returns replace-op payload',
    () async {
      final d = _makeDispatcher(json: _valid());
      final r = await d.applyRecipe(
        name: 'wrap_with_card',
        args: <String, dynamic>{'path': '/ui/pages/home/content'},
        dryRun: true,
      );
      expect(r.success, isTrue);
      final payload = jsonDecode(r.payload!) as Map;
      expect(payload['recipe'], equals('wrap_with_card'));
      final ops = payload['ops'] as List;
      expect(ops.length, equals(1));
      expect(ops[0]['op'], equals('replace'));
      expect((ops[0]['value'] as Map)['type'], equals('card'));
    },
  );

  // ── r45 ──────────────────────────────────────────────────────────────────
  // renamePage checks pipeline before checking same-id; use _FakePipeline.
  test('r45: renamePage fails when oldId == newId', () async {
    final r = await _makeDispatcher(
      json: _valid(),
      pipeline: _FakePipeline(),
    ).renamePage(oldId: 'home', newId: 'home');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('nothing to do'));
  });

  // ── r46 ──────────────────────────────────────────────────────────────────
  test('r46: renamePage fails for empty oldId', () async {
    final r = await _makeDispatcher(
      json: _valid(),
      pipeline: _FakePipeline(),
    ).renamePage(oldId: '', newId: 'new');
    expect(r.success, isFalse);
  });

  // ── r47 ──────────────────────────────────────────────────────────────────
  test('r47: renameTemplate fails for empty ids', () async {
    final r = await _makeDispatcher(
      json: _valid(),
      pipeline: _FakePipeline(),
    ).renameTemplate(oldId: '', newId: 'x');
    expect(r.success, isFalse);
  });

  // ── r48 ──────────────────────────────────────────────────────────────────
  // renameStateKey checks pipeline before checking scope; use _FakePipeline.
  test('r48: renameStateKey returns failure for invalid scope', () async {
    final r = await _makeDispatcher(
      json: _valid(),
      pipeline: _FakePipeline(),
    ).renameStateKey(oldKey: 'count', newKey: 'total', scope: 'invalid_scope');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('scope must be'));
  });

  // ── r49 ──────────────────────────────────────────────────────────────────
  test('r49: widgetShapeAudit fails when canonical not wired', () async {
    final r = await _makeNoCanonical().widgetShapeAudit();
    expect(r.success, isFalse);
  });

  // ── r50 ──────────────────────────────────────────────────────────────────
  test(
    'r50: widgetShapeAudit warns about button with no label or icon',
    () async {
      final d = _makeDispatcher(
        json: <String, dynamic>{
          'ui': <String, dynamic>{
            'pages': <String, dynamic>{
              'p': <String, dynamic>{
                'type': 'page',
                'content': <String, dynamic>{'type': 'button'},
              },
            },
          },
        },
      );
      final r = await d.widgetShapeAudit();
      expect(r.success, isTrue);
      final findings = (jsonDecode(r.payload!) as Map)['findings'] as List;
      final buttonFindings =
          findings.where((f) => f['rule'] == 'button_label_required').toList();
      expect(buttonFindings.isNotEmpty, isTrue);
      expect(buttonFindings[0]['severity'], equals('warn'));
    },
  );

  // ── r51 ──────────────────────────────────────────────────────────────────
  test(
    'r51: widgetShapeAudit warns about text widget with no content',
    () async {
      final d = _makeDispatcher(
        json: <String, dynamic>{
          'ui': <String, dynamic>{
            'pages': <String, dynamic>{
              'p': <String, dynamic>{
                'type': 'page',
                'content': <String, dynamic>{'type': 'text'},
              },
            },
          },
        },
      );
      final r = await d.widgetShapeAudit();
      expect(r.success, isTrue);
      final findings = (jsonDecode(r.payload!) as Map)['findings'] as List;
      final textFindings =
          findings.where((f) => f['rule'] == 'text_content_required').toList();
      expect(textFindings.isNotEmpty, isTrue);
      expect(textFindings[0]['severity'], equals('warn'));
    },
  );

  // ── r52 ──────────────────────────────────────────────────────────────────
  test('r52: widgetShapeAudit fails image missing src', () async {
    final d = _makeDispatcher(
      json: <String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'p': <String, dynamic>{
              'type': 'page',
              'content': <String, dynamic>{'type': 'image'},
            },
          },
        },
      },
    );
    final r = await d.widgetShapeAudit();
    expect(r.success, isTrue);
    final findings = (jsonDecode(r.payload!) as Map)['findings'] as List;
    final imgFindings =
        findings.where((f) => f['rule'] == 'image_src_required').toList();
    expect(imgFindings.isNotEmpty, isTrue);
    expect(imgFindings[0]['severity'], equals('fail'));
  });

  // ── r53 ──────────────────────────────────────────────────────────────────
  test('r53: widgetShapeAudit fails button onTap that is a List', () async {
    final d = _makeDispatcher(
      json: <String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'p': <String, dynamic>{
              'type': 'page',
              'content': <String, dynamic>{
                'type': 'button',
                'label': 'Go',
                'onTap': <dynamic>[
                  <String, dynamic>{'type': 'navigate', 'route': '/x'},
                ],
              },
            },
          },
        },
      },
    );
    final r = await d.widgetShapeAudit();
    expect(r.success, isTrue);
    final findings = (jsonDecode(r.payload!) as Map)['findings'] as List;
    final tapFindings =
        findings.where((f) => f['rule'] == 'onTap_must_be_action').toList();
    expect(tapFindings.isNotEmpty, isTrue);
    expect(tapFindings[0]['severity'], equals('fail'));
  });

  // ── r54 ──────────────────────────────────────────────────────────────────
  test('r54: widgetLint detects empty_container for empty linear', () async {
    final d = _makeDispatcher(
      json: <String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'p': <String, dynamic>{
              'type': 'page',
              'content': <String, dynamic>{
                'type': 'linear',
                'children': <dynamic>[],
              },
            },
          },
        },
      },
    );
    final r = await d.widgetLint();
    expect(r.success, isTrue);
    final findings = (jsonDecode(r.payload!) as Map)['findings'] as List;
    expect(findings.any((f) => f['kind'] == 'empty_container'), isTrue);
  });

  // ── r55 ──────────────────────────────────────────────────────────────────
  test(
    'r55: widgetLint detects redundant_wrapper for unstyled single-child',
    () async {
      final d = _makeDispatcher(
        json: <String, dynamic>{
          'ui': <String, dynamic>{
            'pages': <String, dynamic>{
              'p': <String, dynamic>{
                'type': 'page',
                'content': <String, dynamic>{
                  'type': 'linear',
                  'children': <dynamic>[
                    <String, dynamic>{'type': 'text', 'content': 'hi'},
                  ],
                },
              },
            },
          },
        },
      );
      final r = await d.widgetLint();
      expect(r.success, isTrue);
      final findings = (jsonDecode(r.payload!) as Map)['findings'] as List;
      expect(findings.any((f) => f['kind'] == 'redundant_wrapper'), isTrue);
    },
  );

  // ── r56 ──────────────────────────────────────────────────────────────────
  test('r56: tokenizationAudit detects hardcoded hex color', () async {
    final d = _makeDispatcher(
      json: <String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'p': <String, dynamic>{
              'type': 'page',
              'content': <String, dynamic>{
                'type': 'box',
                'background': '#FF5733',
              },
            },
          },
        },
      },
    );
    final r = await d.tokenizationAudit();
    expect(r.success, isTrue);
    final findings = (jsonDecode(r.payload!) as Map)['findings'] as List;
    final colorFindings = findings.where((f) => f['kind'] == 'color').toList();
    expect(colorFindings.isNotEmpty, isTrue);
    expect(colorFindings[0]['value'], equals('#FF5733'));
  });

  // ── r57 ──────────────────────────────────────────────────────────────────
  test(
    'r57: tokenizationAudit detects hardcoded M3 spacing value 16',
    () async {
      final d = _makeDispatcher(
        json: <String, dynamic>{
          'ui': <String, dynamic>{
            'pages': <String, dynamic>{
              'p': <String, dynamic>{
                'type': 'page',
                'content': <String, dynamic>{'type': 'linear', 'padding': 16},
              },
            },
          },
        },
      );
      final r = await d.tokenizationAudit();
      expect(r.success, isTrue);
      final findings = (jsonDecode(r.payload!) as Map)['findings'] as List;
      final spacingFindings =
          findings.where((f) => f['kind'] == 'spacing').toList();
      expect(spacingFindings.isNotEmpty, isTrue);
      expect(spacingFindings[0]['value'], equals(16));
    },
  );

  // ── r58 ──────────────────────────────────────────────────────────────────
  test('r58: routeAudit fails when canonical not wired', () async {
    final r = await _makeNoCanonical().routeAudit();
    expect(r.success, isFalse);
  });

  // ── r59 ──────────────────────────────────────────────────────────────────
  test(
    'r59: routeAudit reports orphan page and missing initial route',
    () async {
      final d = _makeDispatcher(
        json: <String, dynamic>{
          'ui': <String, dynamic>{
            'pages': <String, dynamic>{
              'home': <String, dynamic>{},
              'orphan': <String, dynamic>{},
            },
            'routes': <String, dynamic>{'/home': 'home'},
            'initialRoute': '/missing',
          },
        },
      );
      final r = await d.routeAudit();
      expect(r.success, isTrue);
      final findings = (jsonDecode(r.payload!) as Map)['findings'] as List;
      final kinds = findings.map((f) => f['kind']).toList();
      expect(kinds, contains('orphan_page'));
      expect(kinds, contains('missing_initial_route'));
    },
  );

  // ── r60 ──────────────────────────────────────────────────────────────────
  test('r60: search fails when canonical not wired', () async {
    final r = await _makeNoCanonical().search(query: 'hello');
    expect(r.success, isFalse);
  });

  // ── r61 ──────────────────────────────────────────────────────────────────
  test('r61: search fails for empty query', () async {
    final r = await _makeDispatcher(json: _valid()).search(query: '');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('query required'));
  });

  // ── r62 ──────────────────────────────────────────────────────────────────
  test('r62: search finds page id matching query', () async {
    final r = await _makeDispatcher(json: _valid()).search(query: 'hom');
    expect(r.success, isTrue);
    final hits = (jsonDecode(r.payload!) as Map)['hits'] as List;
    final pageHits = hits.where((h) => h['kind'] == 'pageId').toList();
    expect(pageHits.isNotEmpty, isTrue);
    expect(pageHits[0]['preview'], equals('home'));
  });

  // ── r63 ──────────────────────────────────────────────────────────────────
  test('r63: themePresetSet rejects invalid preset name', () async {
    final r = await _makeDispatcher().themePresetSet(preset: 'rainbow');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('must be one of'));
  });

  // ── r64 ──────────────────────────────────────────────────────────────────
  test(
    'r64: themePresetSet fails when pipeline not wired for valid preset',
    () async {
      final r = await _makeDispatcher().themePresetSet(preset: 'warm');
      expect(r.success, isFalse);
      expect(r.message.toLowerCase(), contains('pipeline'));
    },
  );

  // ── r65 ──────────────────────────────────────────────────────────────────
  test('r65: i18nLocaleAdd rejects invalid BCP-47 locale tag', () async {
    final r = await _makeDispatcher(
      json: const <String, dynamic>{},
    ).i18nLocaleAdd(tag: 'NOT VALID!!');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('bcp-47'));
  });

  // ── r66 ──────────────────────────────────────────────────────────────────
  test(
    'r66: i18nLocaleAdd is idempotent for already-registered locale',
    () async {
      final d = _makeDispatcher(
        json: <String, dynamic>{
          'ui': <String, dynamic>{
            'i18n': <String, dynamic>{
              'locales': <dynamic>['en', 'ko'],
            },
          },
        },
      );
      final r = await d.i18nLocaleAdd(tag: 'en');
      expect(r.success, isTrue);
      expect(r.message.toLowerCase(), contains('already registered'));
    },
  );

  // ── r67 ──────────────────────────────────────────────────────────────────
  test('r67: i18nLocaleRemove fails when locale not registered', () async {
    final r = await _makeDispatcher(
      json: const <String, dynamic>{},
    ).i18nLocaleRemove(tag: 'fr');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('not registered'));
  });

  // ── r68 ──────────────────────────────────────────────────────────────────
  test(
    'r68: i18nTextDirectionSet rejects direction other than ltr/rtl',
    () async {
      final r = await _makeDispatcher().i18nTextDirectionSet(
        locale: 'ar',
        direction: 'bidi',
      );
      expect(r.success, isFalse);
      expect(r.message.toLowerCase(), contains('ltr / rtl'));
    },
  );

  // ── r69 ──────────────────────────────────────────────────────────────────
  test('r69: navigationItemStyleSet rejects negative index', () async {
    final r = await _makeDispatcher().navigationItemStyleSet(
      index: -1,
      slot: 'backgroundColor',
      value: '#fff',
    );
    expect(r.success, isFalse);
    expect(r.message, contains('>= 0'));
  });

  // ── r70 ──────────────────────────────────────────────────────────────────
  test('r70: serviceSet fails for empty name', () async {
    final r = await _makeDispatcher().serviceSet(name: '');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('name required'));
  });

  // ── r71 ──────────────────────────────────────────────────────────────────
  test('r71: serviceSet fails for invalid kind', () async {
    final r = await _makeDispatcher().serviceSet(name: 'ws', kind: 'websocket');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('kind must be one of'));
  });

  // ── r72 ──────────────────────────────────────────────────────────────────
  test('r72: extractToTemplate fails for invalid template id', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.extractToTemplate(
      widgetPath: '/ui/pages/home/content',
      newTemplateId: '123-invalid',
    );
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('not a valid identifier'));
  });

  // ── r73 ──────────────────────────────────────────────────────────────────
  test('r73: diffApply fails for empty ops list', () async {
    final r = await _makeDispatcher().diffApply(ops: <dynamic>[]);
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('ops required'));
  });

  // ── r74 ──────────────────────────────────────────────────────────────────
  test('r74: diffApply rejects move ops', () async {
    final r = await _makeDispatcher(json: _valid()).diffApply(
      ops: <dynamic>[
        <String, dynamic>{
          'op': 'move',
          'path': '/ui/pages/home',
          'from': '/ui/pages/old',
        },
      ],
    );
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('not supported'));
  });

  // ── r75 ──────────────────────────────────────────────────────────────────
  test('r75: pageCreate fails when canonical not wired', () async {
    final r = await _makeNoCanonical().pageCreate(id: 'newPage');
    expect(r.success, isFalse);
  });

  // ── r76 ──────────────────────────────────────────────────────────────────
  test('r76: pageCreate fails when route does not start with /', () async {
    final r = await _makeDispatcher(
      json: _valid(),
    ).pageCreate(id: 'newPage', route: 'newPage');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('route must start with'));
  });

  // ── r77 ──────────────────────────────────────────────────────────────────
  test('r77: stateProposeForPage fails for empty pageId', () async {
    final r = await _makeDispatcher().stateProposeForPage(pageId: '');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('pageid required'));
  });

  // ── r78 ──────────────────────────────────────────────────────────────────
  test('r78: pendingDiff fails when canonical not wired', () async {
    final r = await _makeNoCanonical().pendingDiff();
    expect(r.success, isFalse);
  });

  // ── r79 ──────────────────────────────────────────────────────────────────
  test('r79: widgetDiff fails when canonical not wired', () async {
    final r = await _makeNoCanonical().widgetDiff(
      path: '/ui/pages/home',
      candidate: <String, dynamic>{'type': 'page'},
    );
    expect(r.success, isFalse);
  });

  // ── r80 ──────────────────────────────────────────────────────────────────
  test('r80: help returns success with all catalog groups', () async {
    final r = await _makeDispatcher().help();
    expect(r.success, isTrue);
    final catalog = jsonDecode(r.payload!) as Map;
    expect(catalog.containsKey('discovery'), isTrue);
    expect(catalog.containsKey('mutation'), isTrue);
    expect(catalog.containsKey('audit_repair'), isTrue);
    expect(catalog.containsKey('presets_recipes'), isTrue);
  });

  // ── r81 ──────────────────────────────────────────────────────────────────
  test('r81: specCard returns failure for unknown topic', () async {
    final r = await _makeDispatcher().specCard(topic: 'nonexistent_topic_xyz');
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('unknown topic'));
  });

  // ── r82 ──────────────────────────────────────────────────────────────────
  test(
    'r82: specCard returns success with non-trivial payload for known topic',
    () async {
      final r = await _makeDispatcher().specCard(topic: 'phase1_decoration');
      expect(r.success, isTrue);
      expect(r.payload!.length, greaterThan(100));
    },
  );

  // ── r83 ──────────────────────────────────────────────────────────────────
  test('r83: dispatch returns null for unknown tool name', () async {
    final r = await _makeDispatcher().dispatch(
      'no_such_tool_xyz',
      <String, dynamic>{},
    );
    expect(r, isNull);
  });

  // ── r84 ──────────────────────────────────────────────────────────────────
  test('r84: dispatch routes read_build_guide to readBuildGuide()', () async {
    final r = await _makeDispatcher().dispatch(
      'read_build_guide',
      <String, dynamic>{},
    );
    expect(r, isNotNull);
    expect(r!.success, isTrue);
    expect(r.message, contains('pattern guide'));
  });

  // ── r85 ──────────────────────────────────────────────────────────────────
  test('r85: dispatch add_child fails when widget.type is missing', () async {
    final r = await _makeDispatcher(json: _valid()).dispatch(
      'add_child',
      <String, dynamic>{
        'parentPath': '/ui/pages',
        'widget': <String, dynamic>{'label': 'missing type'},
      },
    );
    expect(r, isNotNull);
    expect(r!.success, isFalse);
    expect(r.message.toLowerCase(), contains('widget.type required'));
  });

  // ── r86 ──────────────────────────────────────────────────────────────────
  test('r86: getBuildConfig returns success when no preset is saved', () {
    final r = _makeDispatcher().getBuildConfig();
    expect(r.success, isTrue);
  });
}
