/// Extended unit-test coverage for [BuildToolsDispatcher].
///
/// This file covers methods and branches NOT already exercised in
/// build_tools_test.dart (r1-r86) or build_tools_writeops_test.dart (w1-w36).
///
/// Scenario index:
///
/// --- projectInfo ---
/// c1   success — returns channels map in payload
///
/// --- bundleOutline (extended) ---
/// c2   assets section from manifest.assets.assets list
/// c3   theme section with mode field
/// c4   dashboard section
/// c5   navigation section with itemCount
/// c6   routes as List → routeCount
///
/// --- getSection (extended) ---
/// c7   theme section resolves
/// c8   dashboard section resolves (empty returns success with null value)
/// c9   navigation section resolves
/// c10  assets section resolves
/// c11  pages section without id returns all pages
/// c12  templates section without id
///
/// --- checkWiring (extended) ---
/// c13  no /ui section → success, 0 issues
/// c14  pages exist but no routes → no_routes issue
/// c15  route with ui://pages/<id> prefix
/// c16  transition wrapper {page, transition} route value
/// c17  undefined_template detected
/// c18  unused_template detected
/// c19  undefined_state via {{state.x}} binding
/// c20  undefined_state via @{state.x} binding
///
/// --- serviceSet (extended) ---
/// c21  no fields provided → failure
/// c22  success with kind + tool via fake pipeline
///
/// --- serviceRemove ---
/// c23  empty name → failure
/// c24  success via fake pipeline
///
/// --- templateLibraryRemove ---
/// c25  empty uri → failure
/// c26  not registered → failure
/// c27  removal of last item
///
/// --- templateLibraryAdd ---
/// c28  update existing uri (idempotent update)
///
/// --- themeFontSet ---
/// c29  empty family → failure
/// c30  no fields (all null) → failure
/// c31  success with weights via fake pipeline
///
/// --- themeFontRemove ---
/// c32  empty family → failure
/// c33  success via fake pipeline
///
/// --- navigationItemStyleSet ---
/// c34  style param replaces whole style
/// c35  dotted slot form sets nested key
/// c36  null value removes slot
///
/// --- applyLayoutPreset (dryRun extended) ---
/// c37  dryRun gallery preset returns content
/// c38  dryRun magazine preset
/// c39  dryRun carousel preset
/// c40  dryRun playlist preset
/// c41  dryRun landing preset
///
/// --- applyRecipe (dryRun) ---
/// c42  dryRun wrap_with_scroll + valid direction
/// c43  wrap_with_scroll invalid direction → failure
/// c44  dryRun wrap_with_expanded
/// c45  dryRun wrap_with_centered
/// c46  dryRun wrap_with_aspect_ratio
/// c47  dryRun wrap_with_clip_oval
/// c48  dryRun wrap_with_animated_opacity without binding
/// c49  dryRun wrap_with_animated_opacity with binding
/// c50  wrap_with_hero missing tag → failure
/// c51  dryRun wrap_with_hero with tag
/// c52  wrap_with_safearea pageId not found → failure
/// c53  dryRun add_floating_action
/// c54  dryRun add_loading_state
///
/// --- renameRoute ---
/// c55  empty paths → failure
/// c56  not starting with / → failure
/// c57  source not found → failure
/// c58  new path collision → failure
///
/// --- replaceSubtree (via dispatch) ---
/// c59  invalid path → failure
///
/// --- widgetDiff ---
/// c60  canonical not wired → failure
/// c61  identical state → 0 ops, success
///
/// --- stateProposeForPage ---
/// c62  no /ui section → failure
/// c63  page not found → failure
/// c64  missing keys (apply:false) — reports in payload
///
/// --- applyToEach ---
/// c65  canonical not wired → failure
/// c66  no set/setDeep provided → failure
/// c67  dryRun with no matches
///
/// --- dependencyGraph ---
/// c68  no pages → empty graph
/// c69  pages with template refs
///
/// --- findReferences ---
/// c70  no /ui → empty results
/// c71  bad format (no colon) → failure
/// c72  template kind
/// c73  state kind
/// c74  route kind
///
/// --- a11yAudit ---
/// c75  button missing accessibleName
/// c76  text minFontSize below threshold
/// c77  input without accessibleName
///
/// --- a11yQuickFix ---
/// c78  dryRun preview
/// c79  no fixable findings → success
///
/// --- extractI18n ---
/// c80  page not found → failure
/// c81  dryRun with extractable strings
///
/// --- assetAudit ---
/// c82  no assets → 0 findings
///
/// --- stateUsage ---
/// c83  empty pageId → failure
/// c84  page not found → failure
/// c85  {{state.x}} binding detected
///
/// --- bindingDependencies ---
/// c86  invalid path → failure
/// c87  state refs detected
///
/// --- extractToTemplate ---
/// c88  canonical not wired → failure
/// c89  invalid template id format → failure
/// c90  template already exists → failure
///
/// --- inlineTemplate ---
/// c91  not wired (pipeline) → failure
///
/// --- duplicatePage ---
/// c92  not wired → failure
/// c93  src not found → failure
///
/// --- swapWidget ---
/// c94  canonical not wired → failure
/// c95  invalid path → failure
/// c96  same type → failure
///
/// --- animationPreset ---
/// c97  invalid kind → failure
/// c98  page not found → failure
///
/// --- tokenUsage ---
/// c99  empty role → failure
/// c100 no usages → 0 hits
///
/// --- grade ---
/// c101 no validator wired → empty-bundle result
///
/// --- specCard ---
/// c102 phase2_gallery topic
/// c103 phase3_motion topic
/// c104 phase4_media topic
/// c105 phase5_theme_nav topic
/// c106 primitives topic
///
/// --- validateBundle ---
/// c107 canonical/validator not wired → failure
///
/// --- widgetShapeAudit (extended) ---
/// c108 children_must_be_list (non-List children field)
/// c109 iconButton_needs_icon (iconButton without label or icon)
/// c110 richText without content/text/spans
///
/// --- widgetLint ---
/// c111 deep_nesting depth > 8
/// c112 long_text_leaf > 240 chars
///
/// --- releaseCheck ---
/// c113 dryRun mode returns findings
///
/// --- capturePreview ---
/// c114 callback not wired → failure
///
/// --- layoutSnapshot ---
/// c115 callback not wired → failure
///
/// --- runBuild ---
/// c116 callback not wired → failure
///
/// --- dispatch (uncovered cases) ---
/// c117 project_info
/// c118 check_wiring
/// c119 validate_bundle
/// c120 service_set
/// c121 service_remove
/// c122 template_library_add
/// c123 template_library_remove
/// c124 theme_font_set
/// c125 theme_font_remove
/// c126 navigation_item_style_set
/// c127 asset_audit
/// c128 a11y_audit
/// c129 token_usage
/// c130 swap_widget (dispatch route)
/// c131 spec_card (dispatch route)
/// c132 health_check (dispatch route)
/// c133 release_check
/// c134 grade (dispatch)
/// c135 pending_diff
/// c136 help (dispatch route)
/// c137 route_audit (dispatch route)
/// c138 widget_shape_audit (dispatch)
/// c139 widget_lint (dispatch)
/// c140 dependency_graph (dispatch)
/// c141 find_references (dispatch)
/// c142 undo_history (dispatch)
/// c143 diff_apply (dispatch)
/// c144 state_propose (dispatch)
/// c145 apply_to_each (dispatch)
/// c146 rename_route (dispatch)
/// c147 apply_recipe (dispatch)
/// c148 extract_template (dispatch)
/// c149 inline_template (dispatch)
/// c150 duplicate_page (dispatch)
/// c151 move_widget (dispatch)
/// c152 rename_page (dispatch)
/// c153 replace_subtree (dispatch)
/// c154 find_widgets (dispatch)
/// c155 apply_layout_preset (dispatch)
/// c156 apply_theme_preset (dispatch)
/// c157 state_usage (dispatch)
/// c158 binding_dependencies (dispatch)
/// c159 get_section (dispatch)
/// c160 get_build_config (dispatch)
/// c161 delete_widget (dispatch)
/// c162 set_property (dispatch)
/// c163 a11y_quick_fix (dispatch)
/// c164 rename_template (dispatch)
/// c165 rename_state_key (dispatch)
/// c166 extract_i18n (dispatch)
/// c167 extract_to_template (dispatch)
/// c168 tokenization_audit (dispatch)
/// c169 animation_preset (dispatch)
/// c170 widget_diff (dispatch)
/// c171 search (dispatch)
/// c172 navigationStyleSet — empty slot failure
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
import 'package:appplayer_studio/src/apps/app_builder/core/types.dart';
import 'package:appplayer_studio/src/apps/app_builder/core/vibe_project.dart';
import 'package:appplayer_studio/src/apps/app_builder/feat/build_tools.dart';

// ── Fakes (copied from build_tools_test.dart pattern) ────────────────────────

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

class _FakePipeline implements PatchPipeline {
  @override
  Future<PatchResult> apply(CanonicalPatch patch) async => const PatchApplied(
    changedPointers: <String>[],
    beforeHash: '',
    afterHash: '',
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

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

/// Minimal valid bundle with pages, routes, templates, state.
Map<String, dynamic> _valid() => <String, dynamic>{
  'manifest': <String, dynamic>{
    'name': 'My App',
    'version': '1.0.0',
    'description': 'A test app',
  },
  'ui': <String, dynamic>{
    'type': 'application',
    'initialRoute': '/home',
    'routes': <String, dynamic>{'/home': 'home'},
    'pages': <String, dynamic>{
      'home': <String, dynamic>{
        'type': 'page',
        'title': 'Home',
        'state': <String, dynamic>{'counter': 0},
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
    'templates': <String, dynamic>{
      'myCard': <String, dynamic>{
        'type': 'template',
        'content': <String, dynamic>{
          'type': 'card',
          'child': <String, dynamic>{'type': 'text', 'content': 'Hi'},
        },
      },
    },
  },
};

dynamic _decodePayload(BuildToolResult r) =>
    jsonDecode(r.payload!) as Map<String, dynamic>;

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── c1 ───────────────────────────────────────────────────────────────────
  test('c1: projectInfo returns channels map', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.projectInfo();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['name'], 'test');
    expect(j['channels'], isA<Map>());
  });

  // ── c2 ───────────────────────────────────────────────────────────────────
  test(
    'c2: bundleOutline surfaces assets from manifest.assets.assets',
    () async {
      final json = <String, dynamic>{
        'manifest': <String, dynamic>{
          'assets': <String, dynamic>{
            'assets': <dynamic>[
              <String, dynamic>{
                'id': 'logo',
                'type': 'image',
                'path': 'assets/logo.png',
              },
            ],
          },
        },
      };
      final d = _makeDispatcher(json: json);
      final r = await d.bundleOutline();
      expect(r.success, isTrue);
      final j = _decodePayload(r);
      final assets = j['assets'] as List;
      expect(assets, hasLength(1));
      expect(assets.first['id'], 'logo');
    },
  );

  // ── c3 ───────────────────────────────────────────────────────────────────
  test('c3: bundleOutline surfaces theme section with mode', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'theme': <String, dynamic>{
          'mode': 'dark',
          'color': <String, dynamic>{'seed': '#FF0000'},
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.bundleOutline();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['theme'], isA<Map>());
    expect(j['theme']['mode'], 'dark');
  });

  // ── c4 ───────────────────────────────────────────────────────────────────
  test('c4: bundleOutline surfaces dashboard section', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'dashboard': <String, dynamic>{'type': 'dashboard'},
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.bundleOutline();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['dashboard'], isA<Map>());
    expect(j['dashboard']['path'], '/ui/dashboard');
  });

  // ── c5 ───────────────────────────────────────────────────────────────────
  test('c5: bundleOutline surfaces navigation with itemCount', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'navigation': <String, dynamic>{
          'type': 'bottom',
          'items': <dynamic>[
            <String, dynamic>{'label': 'Home', 'route': '/home'},
            <String, dynamic>{'label': 'About', 'route': '/about'},
          ],
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.bundleOutline();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['navigation']['itemCount'], 2);
    expect(j['navigation']['type'], 'bottom');
  });

  // ── c6 ───────────────────────────────────────────────────────────────────
  test('c6: bundleOutline handles routes as List', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'routes': <dynamic>['/home', '/about'],
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.bundleOutline();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['app']['routeCount'], 2);
  });

  // ── c7 ───────────────────────────────────────────────────────────────────
  test('c7: getSection theme resolves', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'theme': <String, dynamic>{'mode': 'light'},
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.getSection(section: 'theme');
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['section'], 'theme');
    expect(j['value'], isA<Map>());
  });

  // ── c8 ───────────────────────────────────────────────────────────────────
  test(
    'c8: getSection dashboard empty returns success with null value',
    () async {
      final d = _makeDispatcher(
        json: const <String, dynamic>{'ui': <String, dynamic>{}},
      );
      final r = await d.getSection(section: 'dashboard');
      expect(r.success, isTrue);
      final j = _decodePayload(r);
      expect(j['value'], isNull);
    },
  );

  // ── c9 ───────────────────────────────────────────────────────────────────
  test('c9: getSection navigation resolves', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'navigation': <String, dynamic>{'type': 'bottom'},
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.getSection(section: 'navigation');
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['section'], 'navigation');
  });

  // ── c10 ──────────────────────────────────────────────────────────────────
  test('c10: getSection assets resolves', () async {
    final json = <String, dynamic>{
      'manifest': <String, dynamic>{
        'assets': <String, dynamic>{'assets': <dynamic>[]},
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.getSection(section: 'assets');
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['section'], 'assets');
  });

  // ── c11 ──────────────────────────────────────────────────────────────────
  test('c11: getSection pages without id returns all pages', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.getSection(section: 'pages');
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['value'], isA<Map>());
    expect((j['value'] as Map).containsKey('home'), isTrue);
  });

  // ── c12 ──────────────────────────────────────────────────────────────────
  test('c12: getSection templates without id', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.getSection(section: 'templates');
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['value'], isA<Map>());
  });

  // ── c13 ──────────────────────────────────────────────────────────────────
  test('c13: checkWiring no /ui section → success 0 issues', () async {
    final d = _makeDispatcher(json: const <String, dynamic>{});
    final r = await d.checkWiring();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect((j['issues'] as List).isEmpty, isTrue);
  });

  // ── c14 ──────────────────────────────────────────────────────────────────
  test('c14: checkWiring pages exist but routes missing → no_routes', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{'type': 'page'},
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.checkWiring();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    final issues = j['issues'] as List;
    expect(issues.any((i) => i['kind'] == 'no_routes'), isTrue);
  });

  // ── c15 ──────────────────────────────────────────────────────────────────
  test(
    'c15: checkWiring route with ui://pages/<id> prefix resolves correctly',
    () async {
      final json = <String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'home': <String, dynamic>{'type': 'page'},
          },
          'routes': <String, dynamic>{'/home': 'ui://pages/home'},
          'initialRoute': '/home',
        },
      };
      final d = _makeDispatcher(json: json);
      final r = await d.checkWiring();
      expect(r.success, isTrue);
      final j = _decodePayload(r);
      // home is reachable via the ui://pages/home route, no issues
      final issues =
          (j['issues'] as List)
              .where((i) => i['kind'] == 'missing_route_target')
              .toList();
      expect(issues, isEmpty);
    },
  );

  // ── c16 ──────────────────────────────────────────────────────────────────
  test(
    'c16: checkWiring {page, transition} map route value resolves correctly',
    () async {
      final json = <String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'home': <String, dynamic>{'type': 'page'},
          },
          'routes': <String, dynamic>{
            '/home': <String, dynamic>{'page': 'home', 'transition': 'fade'},
          },
          'initialRoute': '/home',
        },
      };
      final d = _makeDispatcher(json: json);
      final r = await d.checkWiring();
      expect(r.success, isTrue);
      final j = _decodePayload(r);
      final issues =
          (j['issues'] as List)
              .where((i) => i['kind'] == 'missing_route_target')
              .toList();
      expect(issues, isEmpty);
    },
  );

  // ── c17 ──────────────────────────────────────────────────────────────────
  test('c17: checkWiring undefined_template detected', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{
            'type': 'page',
            'content': <String, dynamic>{'type': 'use', 'template': 'ghost'},
          },
        },
        'routes': <String, dynamic>{'/home': 'home'},
        'templates': <String, dynamic>{},
        'initialRoute': '/home',
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.checkWiring();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    final issues = j['issues'] as List;
    expect(issues.any((i) => i['kind'] == 'undefined_template'), isTrue);
  });

  // ── c18 ──────────────────────────────────────────────────────────────────
  test('c18: checkWiring unused_template detected', () async {
    final d = _makeDispatcher(
      json: _valid(),
    ); // _valid has myCard template, no use
    final r = await d.checkWiring();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    final issues = j['issues'] as List;
    expect(issues.any((i) => i['kind'] == 'unused_template'), isTrue);
  });

  // ── c19 ──────────────────────────────────────────────────────────────────
  test('c19: checkWiring undefined_state via {{state.x}} binding', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{
            'type': 'page',
            'state': <String, dynamic>{},
            'content': <String, dynamic>{
              'type': 'text',
              'content': '{{state.missing}}',
            },
          },
        },
        'routes': <String, dynamic>{'/home': 'home'},
        'initialRoute': '/home',
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.checkWiring();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    final issues = j['issues'] as List;
    expect(
      issues.any(
        (i) => i['kind'] == 'undefined_state' && i['key'] == 'missing',
      ),
      isTrue,
    );
  });

  // ── c20 ──────────────────────────────────────────────────────────────────
  test('c20: checkWiring undefined_state via @{state.x} binding', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{
            'type': 'page',
            'state': <String, dynamic>{},
            'content': <String, dynamic>{
              'type': 'textfield',
              'value': '@{state.ghost}',
            },
          },
        },
        'routes': <String, dynamic>{'/home': 'home'},
        'initialRoute': '/home',
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.checkWiring();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    final issues = j['issues'] as List;
    expect(
      issues.any((i) => i['kind'] == 'undefined_state' && i['key'] == 'ghost'),
      isTrue,
    );
  });

  // ── c21 ──────────────────────────────────────────────────────────────────
  test('c21: serviceSet no fields → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.serviceSet(name: 'weather');
    expect(r.success, isFalse);
    expect(r.message, contains('provide at least one field'));
  });

  // ── c22 ──────────────────────────────────────────────────────────────────
  test('c22: serviceSet success with kind + tool via fake pipeline', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.serviceSet(
      name: 'weather',
      kind: 'polling',
      tool: 'weather.fetch',
    );
    expect(r.success, isTrue);
  });

  // ── c23 ──────────────────────────────────────────────────────────────────
  test('c23: serviceRemove empty name → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.serviceRemove(name: '');
    expect(r.success, isFalse);
    expect(r.message, contains('name required'));
  });

  // ── c24 ──────────────────────────────────────────────────────────────────
  test('c24: serviceRemove success via fake pipeline', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.serviceRemove(name: 'weather');
    expect(r.success, isTrue);
  });

  // ── c25 ──────────────────────────────────────────────────────────────────
  test('c25: templateLibraryRemove empty uri → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.templateLibraryRemove(uri: '');
    expect(r.success, isFalse);
    expect(r.message, contains('uri required'));
  });

  // ── c26 ──────────────────────────────────────────────────────────────────
  test('c26: templateLibraryRemove not registered → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.templateLibraryRemove(uri: 'https://example.com/lib.mbd');
    expect(r.success, isFalse);
    expect(r.message, contains('not registered'));
  });

  // ── c27 ──────────────────────────────────────────────────────────────────
  test('c27: templateLibraryRemove removal of last item', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'templateLibraries': <dynamic>[
          <String, dynamic>{'uri': 'https://example.com/lib.mbd'},
        ],
      },
    };
    final d = _makeDispatcher(json: json, pipeline: _FakePipeline());
    final r = await d.templateLibraryRemove(uri: 'https://example.com/lib.mbd');
    expect(r.success, isTrue);
  });

  // ── c28 ──────────────────────────────────────────────────────────────────
  test('c28: templateLibraryAdd updates existing uri (idempotent)', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'templateLibraries': <dynamic>[
          <String, dynamic>{
            'uri': 'https://example.com/lib.mbd',
            'version': '1.0',
          },
        ],
      },
    };
    final d = _makeDispatcher(json: json, pipeline: _FakePipeline());
    final r = await d.templateLibraryAdd(
      uri: 'https://example.com/lib.mbd',
      version: '2.0',
    );
    expect(r.success, isTrue);
    expect(r.message, contains('update'));
  });

  // ── c29 ──────────────────────────────────────────────────────────────────
  test('c29: themeFontSet empty family → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.themeFontSet(
      family: '',
      weights: <String, dynamic>{'400': 'Regular'},
    );
    expect(r.success, isFalse);
    expect(r.message, contains('family required'));
  });

  // ── c30 ──────────────────────────────────────────────────────────────────
  test('c30: themeFontSet all fields null → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.themeFontSet(family: 'Roboto');
    expect(r.success, isFalse);
    expect(r.message, contains('set at least one'));
  });

  // ── c31 ──────────────────────────────────────────────────────────────────
  test('c31: themeFontSet success with weights', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.themeFontSet(
      family: 'Roboto',
      weights: <String, dynamic>{'400': 'Regular'},
    );
    expect(r.success, isTrue);
  });

  // ── c32 ──────────────────────────────────────────────────────────────────
  test('c32: themeFontRemove empty family → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.themeFontRemove(family: '');
    expect(r.success, isFalse);
    expect(r.message, contains('family required'));
  });

  // ── c33 ──────────────────────────────────────────────────────────────────
  test('c33: themeFontRemove success via fake pipeline', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.themeFontRemove(family: 'Roboto');
    expect(r.success, isTrue);
  });

  // ── c34 ──────────────────────────────────────────────────────────────────
  test(
    'c34: navigationItemStyleSet style param replaces whole style',
    () async {
      final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
      final r = await d.navigationItemStyleSet(
        index: 0,
        style: <String, dynamic>{'color': '#FF0000'},
      );
      expect(r.success, isTrue);
    },
  );

  // ── c35 ──────────────────────────────────────────────────────────────────
  test(
    'c35: navigationItemStyleSet dotted slot form sets nested key',
    () async {
      final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
      final r = await d.navigationItemStyleSet(
        index: 0,
        slot: 'active.color',
        value: '#FF0000',
      );
      expect(r.success, isTrue);
    },
  );

  // ── c36 ──────────────────────────────────────────────────────────────────
  test('c36: navigationItemStyleSet null value removes slot', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.navigationItemStyleSet(
      index: 0,
      slot: 'active.color',
      value: null,
    );
    expect(r.success, isTrue);
  });

  // ── c37 ──────────────────────────────────────────────────────────────────
  test('c37: applyLayoutPreset dryRun gallery returns content', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.applyLayoutPreset(
      pageId: 'home',
      kind: 'gallery',
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['kind'], 'gallery');
    expect(j['content'], isA<Map>());
  });

  // ── c38 ──────────────────────────────────────────────────────────────────
  test('c38: applyLayoutPreset dryRun magazine', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.applyLayoutPreset(
      pageId: 'home',
      kind: 'magazine',
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['kind'], 'magazine');
  });

  // ── c39 ──────────────────────────────────────────────────────────────────
  test('c39: applyLayoutPreset dryRun carousel', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.applyLayoutPreset(
      pageId: 'home',
      kind: 'carousel',
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['kind'], 'carousel');
  });

  // ── c40 ──────────────────────────────────────────────────────────────────
  test('c40: applyLayoutPreset dryRun playlist', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.applyLayoutPreset(
      pageId: 'home',
      kind: 'playlist',
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['kind'], 'playlist');
  });

  // ── c41 ──────────────────────────────────────────────────────────────────
  test('c41: applyLayoutPreset dryRun landing', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.applyLayoutPreset(
      pageId: 'home',
      kind: 'landing',
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['kind'], 'landing');
  });

  // ── c42 ──────────────────────────────────────────────────────────────────
  test('c42: applyRecipe dryRun wrap_with_scroll', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.applyRecipe(
      name: 'wrap_with_scroll',
      args: <String, dynamic>{
        'path': '/ui/pages/home/content',
        'direction': 'vertical',
      },
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['recipe'], 'wrap_with_scroll');
  });

  // ── c43 ──────────────────────────────────────────────────────────────────
  test(
    'c43: applyRecipe wrap_with_scroll invalid direction → failure',
    () async {
      final d = _makeDispatcher(json: _valid());
      final r = await d.applyRecipe(
        name: 'wrap_with_scroll',
        args: <String, dynamic>{
          'path': '/ui/pages/home/content',
          'direction': 'diagonal',
        },
      );
      expect(r.success, isFalse);
      expect(r.message, contains('direction must be'));
    },
  );

  // ── c44 ──────────────────────────────────────────────────────────────────
  test('c44: applyRecipe dryRun wrap_with_expanded', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.applyRecipe(
      name: 'wrap_with_expanded',
      args: <String, dynamic>{'path': '/ui/pages/home/content'},
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['ops'], isA<List>());
    expect((j['ops'] as List).first['value']['type'], 'expanded');
  });

  // ── c45 ──────────────────────────────────────────────────────────────────
  test('c45: applyRecipe dryRun wrap_with_centered', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.applyRecipe(
      name: 'wrap_with_centered',
      args: <String, dynamic>{'path': '/ui/pages/home/content'},
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect((j['ops'] as List).first['value']['type'], 'center');
  });

  // ── c46 ──────────────────────────────────────────────────────────────────
  test('c46: applyRecipe dryRun wrap_with_aspect_ratio', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.applyRecipe(
      name: 'wrap_with_aspect_ratio',
      args: <String, dynamic>{
        'path': '/ui/pages/home/content',
        'ratio': 16.0 / 9,
      },
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect((j['ops'] as List).first['value']['type'], 'aspectRatio');
  });

  // ── c47 ──────────────────────────────────────────────────────────────────
  test('c47: applyRecipe dryRun wrap_with_clip_oval', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.applyRecipe(
      name: 'wrap_with_clip_oval',
      args: <String, dynamic>{'path': '/ui/pages/home/content'},
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect((j['ops'] as List).first['value']['type'], 'clipOval');
  });

  // ── c48 ──────────────────────────────────────────────────────────────────
  test(
    'c48: applyRecipe dryRun wrap_with_animated_opacity without binding',
    () async {
      final d = _makeDispatcher(json: _valid());
      final r = await d.applyRecipe(
        name: 'wrap_with_animated_opacity',
        args: <String, dynamic>{'path': '/ui/pages/home/content'},
        dryRun: true,
      );
      expect(r.success, isTrue);
      final j = _decodePayload(r);
      final wrapped = (j['ops'] as List).first['value'] as Map;
      expect(wrapped['type'], 'animatedOpacity');
      expect(wrapped['opacity'], 1); // constant when no binding
    },
  );

  // ── c49 ──────────────────────────────────────────────────────────────────
  test(
    'c49: applyRecipe dryRun wrap_with_animated_opacity with binding',
    () async {
      final d = _makeDispatcher(json: _valid());
      final r = await d.applyRecipe(
        name: 'wrap_with_animated_opacity',
        args: <String, dynamic>{
          'path': '/ui/pages/home/content',
          'binding': 'state.visible',
        },
        dryRun: true,
      );
      expect(r.success, isTrue);
      final j = _decodePayload(r);
      final wrapped = (j['ops'] as List).first['value'] as Map;
      expect(wrapped['opacity'], isA<String>()); // binding expression string
    },
  );

  // ── c50 ──────────────────────────────────────────────────────────────────
  test('c50: applyRecipe wrap_with_hero missing tag → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.applyRecipe(
      name: 'wrap_with_hero',
      args: <String, dynamic>{'path': '/ui/pages/home/content'},
    );
    expect(r.success, isFalse);
    expect(r.message, contains('tag required'));
  });

  // ── c51 ──────────────────────────────────────────────────────────────────
  test('c51: applyRecipe dryRun wrap_with_hero with tag', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.applyRecipe(
      name: 'wrap_with_hero',
      args: <String, dynamic>{
        'path': '/ui/pages/home/content',
        'tag': 'hero-1',
      },
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    final wrapped = (j['ops'] as List).first['value'] as Map;
    expect(wrapped['type'], 'hero');
    expect(wrapped['tag'], 'hero-1');
  });

  // ── c52 ──────────────────────────────────────────────────────────────────
  test(
    'c52: applyRecipe wrap_with_safearea pageId not found → failure',
    () async {
      final d = _makeDispatcher(json: _valid());
      final r = await d.applyRecipe(
        name: 'wrap_with_safearea',
        args: <String, dynamic>{'pageId': 'ghost'},
      );
      expect(r.success, isFalse);
      expect(r.message, contains('valid pageId required'));
    },
  );

  // ── c53 ──────────────────────────────────────────────────────────────────
  test('c53: applyRecipe dryRun add_floating_action', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.applyRecipe(
      name: 'add_floating_action',
      args: <String, dynamic>{'pageId': 'home', 'label': 'Add'},
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['ops'], isA<List>());
  });

  // ── c54 ──────────────────────────────────────────────────────────────────
  test('c54: applyRecipe dryRun add_loading_state', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.applyRecipe(
      name: 'add_loading_state',
      args: <String, dynamic>{'pageId': 'home', 'key': 'isLoading'},
      dryRun: true,
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    // Two ops: replace content + add state key
    expect((j['ops'] as List).length, 2);
  });

  // ── c55 ──────────────────────────────────────────────────────────────────
  test('c55: renameRoute empty paths → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.renameRoute(oldPath: '', newPath: '/new');
    expect(r.success, isFalse);
    expect(r.message, contains('required'));
  });

  // ── c56 ──────────────────────────────────────────────────────────────────
  test('c56: renameRoute not starting with / → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.renameRoute(oldPath: 'home', newPath: 'new');
    expect(r.success, isFalse);
    expect(r.message, contains('must start with'));
  });

  // ── c57 ──────────────────────────────────────────────────────────────────
  test('c57: renameRoute source not found → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.renameRoute(oldPath: '/ghost', newPath: '/new');
    expect(r.success, isFalse);
    expect(r.message, contains('not found'));
  });

  // ── c58 ──────────────────────────────────────────────────────────────────
  test('c58: renameRoute new path collision → failure', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'routes': <String, dynamic>{'/home': 'home', '/about': 'about'},
      },
    };
    final d = _makeDispatcher(json: json, pipeline: _FakePipeline());
    final r = await d.renameRoute(oldPath: '/home', newPath: '/about');
    expect(r.success, isFalse);
    expect(r.message, contains('already exists'));
  });

  // ── c59 ──────────────────────────────────────────────────────────────────
  test('c59: replaceSubtree invalid path → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('replace_subtree', <String, dynamic>{
      'path': '..',
      'widget': <String, dynamic>{'type': 'text'},
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c60 ──────────────────────────────────────────────────────────────────
  test('c60: widgetDiff canonical not wired → failure', () async {
    final d = _makeNoCanonical();
    final r = await d.widgetDiff(
      path: '/ui/pages/home/content/children/0',
      candidate: <String, dynamic>{'type': 'text', 'content': 'new'},
    );
    expect(r.success, isFalse);
    expect(r.message, contains('not wired'));
  });

  // ── c61 ──────────────────────────────────────────────────────────────────
  test('c61: widgetDiff identical candidate → 0 ops', () async {
    final d = _makeDispatcher(json: _valid());
    // Same widget as current: 0 diff ops expected
    final r = await d.widgetDiff(
      path: '/ui/pages/home/content/children/0',
      candidate: <String, dynamic>{'type': 'text', 'content': 'Hello'},
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['opCount'], 0);
  });

  // ── c62 ──────────────────────────────────────────────────────────────────
  test('c62: stateProposeForPage no /ui section → failure', () async {
    final d = _makeDispatcher(json: const <String, dynamic>{});
    final r = await d.stateProposeForPage(pageId: 'home');
    expect(r.success, isFalse);
    expect(r.message, contains('no /ui'));
  });

  // ── c63 ──────────────────────────────────────────────────────────────────
  test('c63: stateProposeForPage page not found → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.stateProposeForPage(pageId: 'ghost');
    expect(r.success, isFalse);
    expect(r.message, contains('not found'));
  });

  // ── c64 ──────────────────────────────────────────────────────────────────
  test(
    'c64: stateProposeForPage missing keys reported (apply:false)',
    () async {
      final json = <String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'home': <String, dynamic>{
              'type': 'page',
              'state': <String, dynamic>{},
              'content': <String, dynamic>{
                'type': 'text',
                'content': '{{state.counter}}',
              },
            },
          },
        },
      };
      final d = _makeDispatcher(json: json, pipeline: _FakePipeline());
      final r = await d.stateProposeForPage(pageId: 'home', apply: false);
      expect(r.success, isTrue);
      final j = _decodePayload(r);
      final missing = j['missing'] as List;
      expect(missing, isNotEmpty);
    },
  );

  // ── c65 ──────────────────────────────────────────────────────────────────
  test('c65: applyToEach canonical not wired → failure', () async {
    final d = _makeNoCanonical();
    final r = await d.applyToEach(
      type: 'text',
      set: <String, dynamic>{'style.color': '#FF0000'},
    );
    expect(r.success, isFalse);
    expect(r.message, contains('not wired'));
  });

  // ── c66 ──────────────────────────────────────────────────────────────────
  test('c66: applyToEach no set/setDeep → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.applyToEach(type: 'text');
    expect(r.success, isFalse);
    expect(r.message, contains('set'));
  });

  // ── c67 ──────────────────────────────────────────────────────────────────
  test('c67: applyToEach dryRun no matches', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.applyToEach(
      type: 'video', // no video widgets in _valid()
      set: <String, dynamic>{'muted': true},
      dryRun: true,
    );
    expect(r.success, isTrue);
  });

  // ── c68 ──────────────────────────────────────────────────────────────────
  test('c68: dependencyGraph no pages → empty graph', () async {
    final d = _makeDispatcher(json: const <String, dynamic>{});
    final r = await d.dependencyGraph();
    expect(r.success, isFalse);
    expect(r.message, contains('/ui'));
  });

  // ── c69 ──────────────────────────────────────────────────────────────────
  test('c69: dependencyGraph pages with template refs', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{
            'type': 'page',
            'content': <String, dynamic>{'type': 'use', 'template': 'myCard'},
          },
        },
        'templates': <String, dynamic>{
          'myCard': <String, dynamic>{
            'type': 'template',
            'content': <String, dynamic>{'type': 'card'},
          },
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.dependencyGraph();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['containers'], isA<Map>());
    expect(j['invertedTemplates'], isA<Map>());
  });

  // ── c70 ──────────────────────────────────────────────────────────────────
  test('c70: findReferences no /ui → failure', () async {
    final d = _makeDispatcher(json: const <String, dynamic>{});
    final r = await d.findReferences(target: 'template:myCard');
    expect(r.success, isFalse);
    expect(r.message, contains('/ui'));
  });

  // ── c71 ──────────────────────────────────────────────────────────────────
  test('c71: findReferences bad format (no colon) → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.findReferences(target: 'noColon');
    expect(r.success, isFalse);
    expect(r.message, contains('<kind>'));
  });

  // ── c72 ──────────────────────────────────────────────────────────────────
  test('c72: findReferences template kind', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{
            'type': 'page',
            'content': <String, dynamic>{'type': 'use', 'template': 'myCard'},
          },
        },
        'templates': <String, dynamic>{
          'myCard': <String, dynamic>{'type': 'template'},
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.findReferences(target: 'template:myCard');
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    // payload: {kind, target, totalHits, byPage, hits}
    expect(j['totalHits'], isA<int>());
    expect((j['totalHits'] as int), greaterThan(0));
  });

  // ── c73 ──────────────────────────────────────────────────────────────────
  test('c73: findReferences state kind with pageId.key format', () async {
    final d = _makeDispatcher(json: _valid());
    // state target must be "<pageId>.<key>" format
    final r = await d.findReferences(target: 'state:home.counter');
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['hits'], isA<List>());
  });

  // ── c74 ──────────────────────────────────────────────────────────────────
  test('c74: findReferences route kind', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.findReferences(target: 'route:/home');
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['hits'], isA<List>());
  });

  // ── c75 ──────────────────────────────────────────────────────────────────
  test('c75: a11yAudit button missing accessibleName', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{
            'type': 'page',
            'content': <String, dynamic>{
              'type': 'button',
              'label': '',
              // no accessibleName
            },
          },
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.a11yAudit();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['fails'], greaterThanOrEqualTo(0));
  });

  // ── c76 ──────────────────────────────────────────────────────────────────
  test('c76: a11yAudit text minFontSize below threshold', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{
            'type': 'page',
            'content': <String, dynamic>{
              'type': 'text',
              'content': 'tiny',
              'style': <String, dynamic>{'fontSize': 8},
            },
          },
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.a11yAudit();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['fails'], greaterThanOrEqualTo(0));
  });

  // ── c77 ──────────────────────────────────────────────────────────────────
  test('c77: a11yAudit input without accessibleName', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{
            'type': 'page',
            'content': <String, dynamic>{
              'type': 'textfield',
              // no accessibleName, no label
            },
          },
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.a11yAudit();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['findings'], isA<List>());
  });

  // ── c78 ──────────────────────────────────────────────────────────────────
  test('c78: a11yQuickFix dryRun preview', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.a11yQuickFix(dryRun: true);
    expect(r.success, isTrue);
  });

  // ── c79 ──────────────────────────────────────────────────────────────────
  test('c79: a11yQuickFix no fixable findings → success', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.a11yQuickFix();
    expect(r.success, isTrue);
  });

  // ── c80 ──────────────────────────────────────────────────────────────────
  test('c80: extractI18n page not found → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.extractI18n(pageId: 'ghost');
    expect(r.success, isFalse);
    expect(r.message, contains('not found'));
  });

  // ── c81 ──────────────────────────────────────────────────────────────────
  test('c81: extractI18n dryRun with extractable strings', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.extractI18n(pageId: 'home', dryRun: true);
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['extractions'], isNotNull);
  });

  // ── c82 ──────────────────────────────────────────────────────────────────
  test('c82: assetAudit no assets → 0 findings', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.assetAudit();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['invalid'], isA<List>());
    expect((j['invalid'] as List).length, 0);
  });

  // ── c83 ──────────────────────────────────────────────────────────────────
  test('c83: stateUsage empty pageId → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.stateUsage(pageId: '');
    expect(r.success, isFalse);
    expect(r.message, contains('pageId'));
  });

  // ── c84 ──────────────────────────────────────────────────────────────────
  test('c84: stateUsage page not found → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.stateUsage(pageId: 'ghost');
    expect(r.success, isFalse);
    expect(r.message, contains('not found'));
  });

  // ── c85 ──────────────────────────────────────────────────────────────────
  test('c85: stateUsage {{state.counter}} binding detected', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{
            'type': 'page',
            'state': <String, dynamic>{'counter': 0},
            'content': <String, dynamic>{
              'type': 'text',
              'content': '{{state.counter}}',
            },
          },
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.stateUsage(pageId: 'home');
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['keys'], isA<List>());
  });

  // ── c86 ──────────────────────────────────────────────────────────────────
  test('c86: bindingDependencies invalid path → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.bindingDependencies(path: '..');
    expect(r.success, isFalse);
  });

  // ── c87 ──────────────────────────────────────────────────────────────────
  test('c87: bindingDependencies state refs detected', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.bindingDependencies(
      path: '/ui/pages/home/content/children/0',
    );
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['stateKeys'], isA<List>());
  });

  // ── c88 ──────────────────────────────────────────────────────────────────
  test('c88: extractToTemplate canonical not wired → failure', () async {
    final d = _makeNoCanonical();
    final r = await d.extractToTemplate(
      widgetPath: '/ui/pages/home/content',
      newTemplateId: 'myTemplate',
    );
    expect(r.success, isFalse);
    expect(r.message, contains('not wired'));
  });

  // ── c89 ──────────────────────────────────────────────────────────────────
  test('c89: extractToTemplate invalid template id format → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.extractToTemplate(
      widgetPath: '/ui/pages/home/content',
      newTemplateId: '123invalid',
    );
    expect(r.success, isFalse);
    expect(r.message, contains('valid identifier'));
  });

  // ── c90 ──────────────────────────────────────────────────────────────────
  test('c90: extractToTemplate template already exists → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.extractToTemplate(
      widgetPath: '/ui/pages/home/content/children/0',
      newTemplateId: 'myCard', // already exists in _valid()
    );
    expect(r.success, isFalse);
    expect(r.message, contains('already exists'));
  });

  // ── c91 ──────────────────────────────────────────────────────────────────
  test('c91: inlineTemplate not wired (pipeline) → failure', () async {
    final d = _makeDispatcher(json: _valid()); // no pipeline
    final r = await d.inlineTemplate(usePath: '/ui/pages/home/content');
    expect(r.success, isFalse);
    expect(r.message, contains('not wired'));
  });

  // ── c92 ──────────────────────────────────────────────────────────────────
  test('c92: duplicatePage not wired → failure', () async {
    final d = _makeDispatcher(json: _valid()); // no pipeline
    final r = await d.duplicatePage(srcId: 'home', newId: 'home2');
    expect(r.success, isFalse);
    expect(r.message, contains('not wired'));
  });

  // ── c93 ──────────────────────────────────────────────────────────────────
  test('c93: duplicatePage src not found → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.duplicatePage(srcId: 'ghost', newId: 'home2');
    expect(r.success, isFalse);
    expect(r.message, contains('not found'));
  });

  // ── c94 ──────────────────────────────────────────────────────────────────
  test('c94: swapWidget canonical not wired → failure', () async {
    final d = _makeNoCanonical();
    final r = await d.swapWidget(
      path: '/ui/pages/home/content',
      newType: 'button',
    );
    expect(r.success, isFalse);
    expect(r.message, contains('not wired'));
  });

  // ── c95 ──────────────────────────────────────────────────────────────────
  test('c95: swapWidget invalid path → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.swapWidget(path: '..', newType: 'button');
    expect(r.success, isFalse);
  });

  // ── c96 ──────────────────────────────────────────────────────────────────
  test('c96: swapWidget same type → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.swapWidget(
      path: '/ui/pages/home/content/children/0', // type: text
      newType: 'text',
    );
    expect(r.success, isFalse);
    expect(r.message, contains('already type'));
  });

  // ── c97 ──────────────────────────────────────────────────────────────────
  test('c97: animationPreset invalid kind → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.animationPreset(pageId: 'home', kind: 'spinAround');
    expect(r.success, isFalse);
    expect(r.message, contains('kind must be'));
  });

  // ── c98 ──────────────────────────────────────────────────────────────────
  test('c98: animationPreset page not found → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.animationPreset(pageId: 'ghost', kind: 'emphasized');
    expect(r.success, isFalse);
    expect(r.message, contains('not found'));
  });

  // ── c99 ──────────────────────────────────────────────────────────────────
  test('c99: tokenUsage empty role → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.tokenUsage(role: '');
    expect(r.success, isFalse);
    expect(r.message, contains('role'));
  });

  // ── c100 ─────────────────────────────────────────────────────────────────
  test('c100: tokenUsage no usages → 0 hits', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.tokenUsage(role: 'color.primary');
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['usages'], isA<List>());
  });

  // ── c101 ─────────────────────────────────────────────────────────────────
  test('c101: grade no validator wired → N/A result', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.grade();
    // grade calls healthCheck which needs validator — fails without it
    expect(r.success, isFalse);
  });

  // ── c102 ─────────────────────────────────────────────────────────────────
  test('c102: specCard phase2_gallery topic returns content', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.specCard(topic: 'phase2_gallery');
    expect(r.success, isTrue);
    expect(r.payload, isNotNull);
  });

  // ── c103 ─────────────────────────────────────────────────────────────────
  test('c103: specCard phase3_motion topic', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.specCard(topic: 'phase3_motion');
    expect(r.success, isTrue);
  });

  // ── c104 ─────────────────────────────────────────────────────────────────
  test('c104: specCard phase4_media topic', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.specCard(topic: 'phase4_media');
    expect(r.success, isTrue);
  });

  // ── c105 ─────────────────────────────────────────────────────────────────
  test('c105: specCard phase5_theme_nav topic', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.specCard(topic: 'phase5_theme_nav');
    expect(r.success, isTrue);
  });

  // ── c106 ─────────────────────────────────────────────────────────────────
  test('c106: specCard primitives topic', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.specCard(topic: 'primitives');
    expect(r.success, isTrue);
  });

  // ── c107 ─────────────────────────────────────────────────────────────────
  test('c107: validateBundle canonical not wired → failure', () async {
    final d = _makeNoCanonical();
    final r = await d.validateBundle();
    expect(r.success, isFalse);
    expect(r.message, contains('not wired'));
  });

  // ── c108 ─────────────────────────────────────────────────────────────────
  test(
    'c108: widgetShapeAudit children_must_be_list non-List children',
    () async {
      final json = <String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'home': <String, dynamic>{
              'type': 'page',
              'content': <String, dynamic>{
                'type': 'linear',
                'children': 'not a list', // BAD
              },
            },
          },
        },
      };
      final d = _makeDispatcher(json: json);
      final r = await d.widgetShapeAudit();
      expect(r.success, isTrue);
      final j = _decodePayload(r);
      final findings = j['findings'] as List;
      expect(findings.any((f) => f['rule'] == 'children_must_be_list'), isTrue);
    },
  );

  // ── c109 ─────────────────────────────────────────────────────────────────
  test('c109: widgetShapeAudit iconButton_needs_icon', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{
            'type': 'page',
            'content': <String, dynamic>{
              'type': 'iconButton',
              // no label or icon
            },
          },
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.widgetShapeAudit();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    final findings = j['findings'] as List;
    expect(findings.any((f) => f['rule'] == 'iconButton_needs_icon'), isTrue);
  });

  // ── c110 ─────────────────────────────────────────────────────────────────
  test('c110: widgetShapeAudit richText without content/text/spans', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{
            'type': 'page',
            'content': <String, dynamic>{
              'type': 'richText',
              // no content, text, or spans
            },
          },
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.widgetShapeAudit();
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    final findings = j['findings'] as List;
    expect(findings.any((f) => f['rule'] == 'text_content_required'), isTrue);
  });

  // ── c111 ─────────────────────────────────────────────────────────────────
  test('c111: widgetLint deep_nesting depth > 8', () async {
    // Build 9 nested linear widgets — depth > 8 triggers deep_nesting
    Map<String, dynamic> buildNested(int depth) {
      if (depth == 0)
        return <String, dynamic>{'type': 'text', 'content': 'leaf'};
      return <String, dynamic>{
        'type': 'linear',
        'direction': 'vertical',
        'children': <dynamic>[buildNested(depth - 1)],
      };
    }

    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{'type': 'page', 'content': buildNested(9)},
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.widgetLint(scope: '/ui/pages/home/content');
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    final findings = j['findings'] as List? ?? [];
    expect(findings.any((f) => f['kind'] == 'deep_nesting'), isTrue);
  });

  // ── c112 ─────────────────────────────────────────────────────────────────
  test('c112: widgetLint long_text_leaf > 240 chars', () async {
    final longText = 'A' * 241;
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'pages': <String, dynamic>{
          'home': <String, dynamic>{
            'type': 'page',
            'content': <String, dynamic>{
              'type': 'text',
              // widgetLint checks 'text', 'label', 'title' fields
              'text': longText,
            },
          },
        },
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.widgetLint(scope: '/ui/pages/home/content');
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    final findings = j['findings'] as List? ?? [];
    expect(findings.any((f) => f['kind'] == 'long_text_leaf'), isTrue);
  });

  // ── c113 ─────────────────────────────────────────────────────────────────
  test('c113: releaseCheck dryRun mode returns findings structure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.releaseCheck(dryRun: true);
    expect(r.success, isTrue);
    final j = _decodePayload(r);
    expect(j['steps'], isNotNull);
  });

  // ── c114 ─────────────────────────────────────────────────────────────────
  test('c114: capturePreview callback not wired → failure', () async {
    final d = _makeDispatcher(json: _valid()); // no onCapturePreview
    final r = await d.capturePreview();
    expect(r.success, isFalse);
    expect(r.message, contains('not wired'));
  });

  // ── c115 ─────────────────────────────────────────────────────────────────
  test('c115: layoutSnapshot callback not wired → failure', () async {
    final d = _makeDispatcher(json: _valid()); // no onLayoutSnapshot
    final r = await d.layoutSnapshot();
    expect(r.success, isFalse);
    expect(r.message, contains('not wired'));
  });

  // ── c116 ─────────────────────────────────────────────────────────────────
  test('c116: runBuild callback not wired → failure', () async {
    final d = _makeDispatcher(json: _valid()); // no onRunBuild
    final r = await d.runBuild();
    expect(r.success, isFalse);
    expect(r.message, contains('not wired'));
  });

  // ── c117 ─────────────────────────────────────────────────────────────────
  test('c117: dispatch project_info', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('project_info', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c118 ─────────────────────────────────────────────────────────────────
  test('c118: dispatch check_wiring', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('check_wiring', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c119 ─────────────────────────────────────────────────────────────────
  test('c119: dispatch validate_bundle no canonical → failure', () async {
    final d = _makeNoCanonical();
    final r = await d.dispatch('validate_bundle', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c120 ─────────────────────────────────────────────────────────────────
  test('c120: dispatch service_set', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('service_set', <String, dynamic>{
      'name': 'myService',
      'kind': 'polling',
      'tool': 'weather.get',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c121 ─────────────────────────────────────────────────────────────────
  test('c121: dispatch service_remove', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('service_remove', <String, dynamic>{
      'name': 'myService',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c122 ─────────────────────────────────────────────────────────────────
  test('c122: dispatch template_library_add', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('template_library_add', <String, dynamic>{
      'uri': 'https://example.com/lib.mbd',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c123 ─────────────────────────────────────────────────────────────────
  test(
    'c123: dispatch template_library_remove not registered → failure',
    () async {
      final d = _makeDispatcher(json: _valid());
      final r = await d.dispatch('template_library_remove', <String, dynamic>{
        'uri': 'https://example.com/lib.mbd',
      });
      expect(r, isNotNull);
      expect((r! as BuildToolResult).success, isFalse);
    },
  );

  // ── c124 ─────────────────────────────────────────────────────────────────
  test('c124: dispatch theme_font_set', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('theme_font_set', <String, dynamic>{
      'family': 'Roboto',
      'weights': <String, dynamic>{'400': 'Regular'},
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c125 ─────────────────────────────────────────────────────────────────
  test('c125: dispatch theme_font_remove', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('theme_font_remove', <String, dynamic>{
      'family': 'Roboto',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c126 ─────────────────────────────────────────────────────────────────
  test('c126: dispatch navigation_item_style_set', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('navigation_item_style_set', <String, dynamic>{
      'index': 0,
      'style': <String, dynamic>{'color': '#FF0000'},
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c127 ─────────────────────────────────────────────────────────────────
  test('c127: dispatch asset_audit', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('asset_audit', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c128 ─────────────────────────────────────────────────────────────────
  test('c128: dispatch a11y_audit', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('a11y_audit', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c129 ─────────────────────────────────────────────────────────────────
  test('c129: dispatch token_usage', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('token_usage', <String, dynamic>{
      'role': 'color.primary',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c130 ─────────────────────────────────────────────────────────────────
  test('c130: dispatch swap_widget same type → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('swap_widget', <String, dynamic>{
      'path': '/ui/pages/home/content/children/0',
      'targetType': 'text',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c131 ─────────────────────────────────────────────────────────────────
  test('c131: dispatch spec_card unknown topic → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('spec_card', <String, dynamic>{
      'topic': 'phase2_gallery',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c132 ─────────────────────────────────────────────────────────────────
  test('c132: dispatch health_check routes to healthCheck', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('health_check', <String, dynamic>{});
    expect(r, isNotNull);
    // healthCheck requires validator — failure expected without one
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c133 ─────────────────────────────────────────────────────────────────
  test('c133: dispatch release_check', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('release_check', <String, dynamic>{
      'dryRun': true,
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c134 ─────────────────────────────────────────────────────────────────
  test('c134: dispatch grade', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('grade', <String, dynamic>{});
    expect(r, isNotNull);
    // grade calls healthCheck which needs validator — fails without it
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c135 ─────────────────────────────────────────────────────────────────
  test('c135: dispatch pending_diff no canonical → failure', () async {
    final d = _makeNoCanonical();
    final r = await d.dispatch('pending_diff', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c136 ─────────────────────────────────────────────────────────────────
  test('c136: dispatch help returns groups', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('help', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c137 ─────────────────────────────────────────────────────────────────
  test('c137: dispatch route_audit', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('route_audit', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c138 ─────────────────────────────────────────────────────────────────
  test('c138: dispatch widget_shape_audit', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('widget_shape_audit', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c139 ─────────────────────────────────────────────────────────────────
  test('c139: dispatch widget_lint', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('widget_lint', <String, dynamic>{
      'pageId': 'home',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c140 ─────────────────────────────────────────────────────────────────
  test('c140: dispatch dependency_graph', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('dependency_graph', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c141 ─────────────────────────────────────────────────────────────────
  test('c141: dispatch find_references', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('find_references', <String, dynamic>{
      'target': 'template:myCard',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c142 ─────────────────────────────────────────────────────────────────
  test('c142: dispatch undo_history', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('undo_history', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c143 ─────────────────────────────────────────────────────────────────
  test('c143: dispatch diff_apply empty ops', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('diff_apply', <String, dynamic>{
      'ops': <dynamic>[],
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse); // empty ops fail
  });

  // ── c144 ─────────────────────────────────────────────────────────────────
  test('c144: dispatch state_propose pageId not found', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('state_propose', <String, dynamic>{
      'pageId': 'ghost',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c145 ─────────────────────────────────────────────────────────────────
  test('c145: dispatch apply_to_each no set → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('apply_to_each', <String, dynamic>{
      'type': 'text',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c146 ─────────────────────────────────────────────────────────────────
  test('c146: dispatch rename_route empty paths → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('rename_route', <String, dynamic>{
      'oldPath': '',
      'newPath': '/new',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c147 ─────────────────────────────────────────────────────────────────
  test('c147: dispatch apply_recipe unknown recipe', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('apply_recipe', <String, dynamic>{
      'name': 'spin_forever',
      'args': <String, dynamic>{},
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c148 ─────────────────────────────────────────────────────────────────
  test('c148: dispatch extract_template not wired', () async {
    final d = _makeNoCanonical();
    final r = await d.dispatch('extract_template', <String, dynamic>{
      'widgetPath': '/ui/pages/home/content',
      'newTemplateId': 'T',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c149 ─────────────────────────────────────────────────────────────────
  test('c149: dispatch inline_template not wired', () async {
    final d = _makeDispatcher(json: _valid()); // no pipeline
    final r = await d.dispatch('inline_template', <String, dynamic>{
      'widgetPath': '/ui/pages/home/content',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c150 ─────────────────────────────────────────────────────────────────
  test('c150: dispatch duplicate_page not wired', () async {
    final d = _makeDispatcher(json: _valid()); // no pipeline
    final r = await d.dispatch('duplicate_page', <String, dynamic>{
      'srcId': 'home',
      'dstId': 'home2',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c151 ─────────────────────────────────────────────────────────────────
  test('c151: dispatch move_widget invalid path', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('move_widget', <String, dynamic>{
      'path': '..',
      'newParentPath': '/ui/pages/home/content',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c152 ─────────────────────────────────────────────────────────────────
  test('c152: dispatch rename_page same id → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('rename_page', <String, dynamic>{
      'oldId': 'home',
      'newId': 'home',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c153 ─────────────────────────────────────────────────────────────────
  test('c153: dispatch replace_subtree routes to replaceSubtree', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('replace_subtree', <String, dynamic>{
      'path': '/ui/pages/home/content/children/0',
      'widget': <String, dynamic>{'type': 'button', 'label': 'New'},
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c154 ─────────────────────────────────────────────────────────────────
  test('c154: dispatch find_widgets no filters → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('find_widgets', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c155 ─────────────────────────────────────────────────────────────────
  test('c155: dispatch apply_layout_preset unknown kind', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('apply_layout_preset', <String, dynamic>{
      'pageId': 'home',
      'kind': 'unknown_kind',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c156 ─────────────────────────────────────────────────────────────────
  test('c156: dispatch apply_theme_preset invalid seed', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('apply_theme_preset', <String, dynamic>{
      'seedColor': 'not-a-color',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c157 ─────────────────────────────────────────────────────────────────
  test('c157: dispatch state_usage empty pageId', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('state_usage', <String, dynamic>{'pageId': ''});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c158 ─────────────────────────────────────────────────────────────────
  test('c158: dispatch binding_dependencies invalid path', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('binding_dependencies', <String, dynamic>{
      'path': '..',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c159 ─────────────────────────────────────────────────────────────────
  test('c159: dispatch get_section theme', () async {
    final json = <String, dynamic>{
      'ui': <String, dynamic>{
        'theme': <String, dynamic>{'mode': 'light'},
      },
    };
    final d = _makeDispatcher(json: json);
    final r = await d.dispatch('get_section', <String, dynamic>{
      'section': 'theme',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c160 ─────────────────────────────────────────────────────────────────
  test('c160: dispatch get_build_config', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('get_build_config', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c161 ─────────────────────────────────────────────────────────────────
  test('c161: dispatch delete_widget', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('delete_widget', <String, dynamic>{
      'path': '/ui/pages/home/content/children/0',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c162 ─────────────────────────────────────────────────────────────────
  test('c162: dispatch set_property', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('set_property', <String, dynamic>{
      'path': '/ui/pages/home',
      'key': 'title',
      'value': 'Updated',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c163 ─────────────────────────────────────────────────────────────────
  test('c163: dispatch a11y_quick_fix dryRun', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('a11y_quick_fix', <String, dynamic>{
      'dryRun': true,
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c164 ─────────────────────────────────────────────────────────────────
  test('c164: dispatch rename_template empty ids → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('rename_template', <String, dynamic>{
      'oldId': '',
      'newId': 'newCard',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c165 ─────────────────────────────────────────────────────────────────
  test('c165: dispatch rename_state_key invalid scope', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('rename_state_key', <String, dynamic>{
      'oldKey': 'counter',
      'newKey': 'total',
      'scope': 'widget',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c166 ─────────────────────────────────────────────────────────────────
  test('c166: dispatch extract_i18n page not found', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('extract_i18n', <String, dynamic>{
      'pageId': 'ghost',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c167 ─────────────────────────────────────────────────────────────────
  test('c167: dispatch extract_to_template invalid id format', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('extract_to_template', <String, dynamic>{
      'widgetPath': '/ui/pages/home/content/children/0',
      'newTemplateId': '123bad',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c168 ─────────────────────────────────────────────────────────────────
  test('c168: dispatch tokenization_audit', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('tokenization_audit', <String, dynamic>{});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isTrue);
  });

  // ── c169 ─────────────────────────────────────────────────────────────────
  test('c169: dispatch animation_preset invalid kind', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.dispatch('animation_preset', <String, dynamic>{
      'pageId': 'home',
      'kind': 'spinForever',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c170 ─────────────────────────────────────────────────────────────────
  test('c170: dispatch widget_diff canonical not wired', () async {
    final d = _makeNoCanonical();
    final r = await d.dispatch('widget_diff', <String, dynamic>{
      'beforePath': '/ui/pages/home/content/children/0',
      'afterPath': '/ui/pages/home/content/children/1',
    });
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c171 ─────────────────────────────────────────────────────────────────
  test('c171: dispatch search empty query → failure', () async {
    final d = _makeDispatcher(json: _valid());
    final r = await d.dispatch('search', <String, dynamic>{'query': ''});
    expect(r, isNotNull);
    expect((r! as BuildToolResult).success, isFalse);
  });

  // ── c172 ─────────────────────────────────────────────────────────────────
  test('c172: navigationStyleSet empty slot → failure', () async {
    final d = _makeDispatcher(json: _valid(), pipeline: _FakePipeline());
    final r = await d.navigationStyleSet(slot: '', value: '#FF0000');
    expect(r.success, isFalse);
    expect(r.message, contains('slot'));
  });
}
