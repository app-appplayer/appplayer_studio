/// Unit tests for [BuildToolsDispatcher] WRITE-SIDE operations.
///
/// Strategy: construct a REAL WorkspaceCanonicalImpl on a temp .mbd dir,
/// a REAL PatchPipelineImpl (with SpecValidatorImpl), and wire them into
/// BuildToolsDispatcher. After each mutating call, assert that
/// canonical.currentJson actually changed — no gap-hiding mocks on the
/// mutation path.
///
/// Each test gets its own temp dir (setUp/tearDown) to prevent cross-test
/// contention. The VibeProject is the minimal constructor form (not
/// VibeProject.openAt) so no kernel boot is needed.
///
/// Scenario index:
///
/// --- setProperty ---
/// w1  set a new scalar leaf on a widget that exists
/// w2  set a nested key using dot notation
/// w3  set fails when parent path does not exist
///
/// --- addChild ---
/// w4  append a widget to an empty children list
/// w5  insert at index 0 (prepend)
/// w6  addChild fails when parentPath is not a map
///
/// --- deleteWidget ---
/// w7  delete an existing widget from a children list
/// w8  deleteWidget leaves remaining siblings intact
///
/// --- moveWidget ---
/// w9  move a widget from one page-content slot to another page
///
/// --- renamePage (success path) ---
/// w10 rename page key in /ui/pages and propagate to route
///
/// --- renameTemplate (success path) ---
/// w11 rename template id and update use-widget references
///
/// --- renameStateKey (success path) ---
/// w12 rename page-scope state key and rewrite bindings
///
/// --- applyLayoutPreset (dryRun:false) ---
/// w13 hero preset lands on real canonical — content.type == linear
/// w14 form preset seeds state on real canonical
///
/// --- applyRecipe (dryRun:false) ---
/// w15 wrap_with_card applied — canonical widget.type == card
/// w16 wrap_with_padding applied — box with padding
/// w17 add_floating_action — floatingActionButton slot written
/// w18 wrap_with_safearea — content wrapped in safeArea
/// w19 add_loading_state — conditional + state key seeded
///
/// --- diffApply (real ops) ---
/// w20 diffApply single add op mutates canonical
/// w21 diffApply multi-op across different paths
///
/// --- applyThemePreset ---
/// w22 applyThemePreset writes /ui/theme with seed color
///
/// --- pageCreate ---
/// w23 pageCreate creates page + route in one op
/// w24 pageCreate with home:true sets initialRoute
///
/// --- extractToTemplate ---
/// w25 extractToTemplate creates template + replaces with use-widget
///
/// --- i18nLocaleAdd ---
/// w26 i18nLocaleAdd writes /ui/i18n/locales
///
/// --- i18nLocaleRemove ---
/// w27 i18nLocaleRemove removes locale from list
///
/// --- i18nTextSet ---
/// w28 i18nTextSet writes /ui/i18n/text/<locale>/<key>
///
/// --- i18nPluralizationSet ---
/// w29 i18nPluralizationSet writes pluralization map
///
/// --- i18nTextDirectionSet ---
/// w30 i18nTextDirectionSet writes /ui/i18n/textDirection/<locale>
///
/// --- themePresetSet ---
/// w31 themePresetSet writes /ui/theme/preset
///
/// --- themeFontSet ---
/// w32 themeFontSet writes /ui/theme/fonts/<family>
///
/// --- serviceSet ---
/// w33 serviceSet (entry form) writes /ui/services/<name>
///
/// --- renameRoute ---
/// w34 renameRoute moves key in /ui/routes and updates initialRoute
///
/// --- templateLibraryAdd ---
/// w35 templateLibraryAdd writes uri into /ui/templateLibraries list
///
/// --- changedPointers / hash changes ---
/// w36 after any write, hash before != hash after
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart'
    show
        CanonicalPatch,
        LayerId,
        PatchPipelineImpl,
        SpecValidator,
        WorkspaceCanonicalImpl;
import 'package:appplayer_studio/builtin_api.dart' show PatchOp, UserOriginator;
import 'package:appplayer_studio/src/base/infra/workspace_fs_port.dart'
    show FileWorkspaceFsPort;
import 'package:appplayer_studio/src/base/spec/spec_validator.dart'
    show SpecValidatorImpl;
import 'package:appplayer_studio/src/apps/app_builder/core/types.dart';
import 'package:appplayer_studio/src/apps/app_builder/core/vibe_project.dart';
import 'package:appplayer_studio/src/apps/app_builder/feat/build_tools.dart';

// ── helpers ──────────────────────────────────────────────────────────────────

WorkspaceCanonicalImpl _makeCanonical() => WorkspaceCanonicalImpl(
  fsPort: FileWorkspaceFsPort(),
  validator: SpecValidatorImpl(),
);

/// Open a project on [projectDir]. Seeds /ui/pages, /ui/routes, and a
/// home page with a content linear + two children so write-ops have real
/// nodes to target.
Future<BuildToolsDispatcher> _openDispatcher(
  String projectDir,
  WorkspaceCanonicalImpl canonical,
) async {
  // Ensure project dir exists and open canonical on the bundle dir.
  final bundleDir = p.join(projectDir, 'bundles', 'serving.mbd');
  await Directory(bundleDir).create(recursive: true);
  await canonical.open(bundleDir);

  // Seed a meaningful initial bundle so write-ops have real nodes.
  await canonical.applyAtomic(_seedPatch());

  final meta = ProjectMeta(
    name: 'test',
    createdAt: DateTime(2024),
    lastOpenedAt: DateTime(2024),
    channels: <String, ChannelDef>{
      'serving': ChannelDef(subdir: 'bundles/serving.mbd'),
    },
    activeChannel: 'serving',
  );
  final project = VibeProject(
    projectPath: projectDir,
    canonical: canonical,
    meta: meta,
    chatLog: null,
    historyLog: null,
    undoSidecar: null,
  );
  final pipeline = PatchPipelineImpl(
    canonical: canonical,
    validator: SpecValidatorImpl(),
  );
  return BuildToolsDispatcher(
    project: project,
    canonical: canonical,
    pipeline: pipeline,
  );
}

/// Patch that seeds the bundle with a pages + routes + templates + state
/// so all write-op tests have real starting nodes.
CanonicalPatch _seedPatch() => CanonicalPatch(
  layer: LayerId.appStructure,
  ops: <PatchOp>[
    PatchOp(
      op: 'add',
      path: '/ui/pages',
      value: <String, dynamic>{
        'home': <String, dynamic>{
          'type': 'page',
          'title': 'Home',
          'state': <String, dynamic>{'counter': 0},
          'content': <String, dynamic>{
            'type': 'linear',
            'direction': 'vertical',
            'children': <dynamic>[
              <String, dynamic>{'type': 'text', 'content': '{{state.counter}}'},
              <String, dynamic>{'type': 'button', 'label': 'Press'},
            ],
          },
        },
      },
    ),
    PatchOp(
      op: 'add',
      path: '/ui/routes',
      value: <String, dynamic>{'/home': 'home'},
    ),
    PatchOp(op: 'add', path: '/ui/initialRoute', value: '/home'),
    PatchOp(
      op: 'add',
      path: '/ui/templates',
      value: <String, dynamic>{
        'myCard': <String, dynamic>{
          'type': 'template',
          'content': <String, dynamic>{
            'type': 'card',
            'child': <String, dynamic>{'type': 'text', 'content': 'Hi'},
          },
        },
      },
    ),
  ],
  originator: const UserOriginator(),
);

/// Resolve a JSON Pointer [path] inside [root]. Returns null when not found.
dynamic _resolve(Map<String, dynamic> root, String path) {
  if (path == '/' || path.isEmpty) return root;
  final segs =
      (path.startsWith('/') ? path.substring(1) : path)
          .split('/')
          .map((s) => s.replaceAll('~1', '/').replaceAll('~0', '~'))
          .toList();
  dynamic node = root;
  for (final seg in segs) {
    if (node is Map) {
      if (!node.containsKey(seg)) return null;
      node = node[seg];
    } else if (node is List) {
      final i = int.tryParse(seg);
      if (i == null || i < 0 || i >= node.length) return null;
      node = node[i];
    } else {
      return null;
    }
  }
  return node;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late Directory tmpDir;
  late WorkspaceCanonicalImpl canonical;
  late BuildToolsDispatcher d;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('btwops_');
    canonical = _makeCanonical();
    d = await _openDispatcher(tmpDir.path, canonical);
  });

  tearDown(() async {
    try {
      await canonical.dispose();
    } catch (_) {}
    try {
      if (tmpDir.existsSync()) {
        // Retry with recursive once — the bundle dir has sub-files written
        // by WorkspaceCanonicalImpl so a bare delete(recursive:false) fails.
        await tmpDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  // ── w1 ────────────────────────────────────────────────────────────────────
  test('w1: setProperty sets a new scalar on an existing widget', () async {
    final r = await d.setProperty(
      path: '/ui/pages/home/content',
      key: 'gap',
      value: 24,
    );
    expect(r.success, isTrue, reason: r.message);
    final gap = _resolve(canonical.currentJson, '/ui/pages/home/content/gap');
    expect(gap, equals(24));
  });

  // ── w2 ────────────────────────────────────────────────────────────────────
  test('w2: setProperty with dot-notated key writes nested property', () async {
    final r = await d.setProperty(
      path: '/ui/pages/home/content',
      key: 'style.color',
      value: '#FF0000',
    );
    expect(r.success, isTrue, reason: r.message);
    final color = _resolve(
      canonical.currentJson,
      '/ui/pages/home/content/style/color',
    );
    expect(color, equals('#FF0000'));
  });

  // ── w3 ────────────────────────────────────────────────────────────────────
  test('w3: setProperty fails when parent path does not exist', () async {
    final r = await d.setProperty(
      path: '/ui/pages/ghost',
      key: 'title',
      value: 'Ghost',
    );
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('does not exist'));
  });

  // ── w4 ────────────────────────────────────────────────────────────────────
  test('w4: addChild appends a widget to children list', () async {
    final r = await d.addChild(
      parentPath: '/ui/pages/home/content',
      widget: <String, dynamic>{'type': 'text', 'content': 'New child'},
    );
    expect(r.success, isTrue, reason: r.message);
    final children =
        _resolve(canonical.currentJson, '/ui/pages/home/content/children')
            as List;
    // Original had 2 children, now 3.
    expect(children.length, equals(3));
    expect((children[2] as Map)['type'], equals('text'));
    expect((children[2] as Map)['content'], equals('New child'));
  });

  // ── w5 ────────────────────────────────────────────────────────────────────
  test('w5: addChild at index 0 prepends widget', () async {
    final r = await d.addChild(
      parentPath: '/ui/pages/home/content',
      widget: <String, dynamic>{'type': 'button', 'label': 'First'},
      index: 0,
    );
    expect(r.success, isTrue, reason: r.message);
    final children =
        _resolve(canonical.currentJson, '/ui/pages/home/content/children')
            as List;
    expect(children.length, equals(3));
    expect((children[0] as Map)['label'], equals('First'));
  });

  // ── w6 ────────────────────────────────────────────────────────────────────
  test('w6: addChild fails when parentPath resolves to non-map', () async {
    // /ui/initialRoute is a string, not a map.
    final r = await d.addChild(
      parentPath: '/ui/initialRoute',
      widget: <String, dynamic>{'type': 'text', 'content': 'X'},
    );
    expect(r.success, isFalse);
    expect(r.message.toLowerCase(), contains('does not resolve to a node'));
  });

  // ── w7 ────────────────────────────────────────────────────────────────────
  test('w7: deleteWidget removes widget from its parent list', () async {
    // Delete the first child (text widget at index 0).
    final r = await d.deleteWidget(path: '/ui/pages/home/content/children/0');
    expect(r.success, isTrue, reason: r.message);
    final children =
        _resolve(canonical.currentJson, '/ui/pages/home/content/children')
            as List;
    expect(children.length, equals(1));
    expect((children[0] as Map)['type'], equals('button'));
  });

  // ── w8 ────────────────────────────────────────────────────────────────────
  test('w8: deleteWidget leaves remaining sibling intact', () async {
    // Delete button (index 1), text at index 0 must survive.
    final r = await d.deleteWidget(path: '/ui/pages/home/content/children/1');
    expect(r.success, isTrue, reason: r.message);
    final children =
        _resolve(canonical.currentJson, '/ui/pages/home/content/children')
            as List;
    expect(children.length, equals(1));
    expect((children[0] as Map)['content'], equals('{{state.counter}}'));
  });

  // ── w9 ────────────────────────────────────────────────────────────────────
  test('w9: moveWidget moves widget to a new parent', () async {
    // First add a second page with an empty children slot.
    await canonical.applyAtomic(
      CanonicalPatch(
        layer: LayerId.pages,
        ops: <PatchOp>[
          PatchOp(
            op: 'add',
            path: '/ui/pages/about',
            value: <String, dynamic>{
              'type': 'page',
              'title': 'About',
              'content': <String, dynamic>{
                'type': 'linear',
                'direction': 'vertical',
                'children': <dynamic>[],
              },
            },
          ),
        ],
        originator: const UserOriginator(),
      ),
    );

    // Move the text widget (index 0) from home/content to about/content.
    final r = await d.moveWidget(
      path: '/ui/pages/home/content/children/0',
      newParentPath: '/ui/pages/about/content',
    );
    expect(r.success, isTrue, reason: r.message);

    final homeChildren =
        _resolve(canonical.currentJson, '/ui/pages/home/content/children')
            as List;
    final aboutChildren =
        _resolve(canonical.currentJson, '/ui/pages/about/content/children')
            as List;

    expect(homeChildren.length, equals(1));
    expect(aboutChildren.length, equals(1));
    expect((aboutChildren[0] as Map)['type'], equals('text'));
  });

  // ── w10 ───────────────────────────────────────────────────────────────────
  test('w10: renamePage moves page key and updates route reference', () async {
    final r = await d.renamePage(oldId: 'home', newId: 'main');
    expect(r.success, isTrue, reason: r.message);

    final json = canonical.currentJson;
    final pages = _resolve(json, '/ui/pages') as Map;
    expect(pages.containsKey('home'), isFalse);
    expect(pages.containsKey('main'), isTrue);

    // Route pointing at 'home' should now point at 'main'.
    final routes = _resolve(json, '/ui/routes') as Map;
    expect(routes.values, contains('main'));
    expect(routes.values, isNot(contains('home')));
  });

  // ── w11 ───────────────────────────────────────────────────────────────────
  test(
    'w11: renameTemplate renames key and rewrites use-widget references',
    () async {
      // First add a use-widget that references myCard.
      await canonical.applyAtomic(
        CanonicalPatch(
          layer: LayerId.pages,
          ops: <PatchOp>[
            PatchOp(
              op: 'add',
              path: '/ui/pages/home/content/children/0/useRef',
              value: null,
            ),
          ],
          originator: const UserOriginator(),
        ),
      );
      // Add a proper use widget referencing myCard.
      await canonical.applyAtomic(
        CanonicalPatch(
          layer: LayerId.pages,
          ops: <PatchOp>[
            PatchOp(
              op: 'add',
              path: '/ui/pages/home/content/children/2',
              value: <String, dynamic>{'type': 'use', 'template': 'myCard'},
            ),
          ],
          originator: const UserOriginator(),
        ),
      );

      final r = await d.renameTemplate(oldId: 'myCard', newId: 'heroCard');
      expect(r.success, isTrue, reason: r.message);

      final json = canonical.currentJson;
      final templates = _resolve(json, '/ui/templates') as Map;
      expect(templates.containsKey('myCard'), isFalse);
      expect(templates.containsKey('heroCard'), isTrue);

      // use-widget should now reference heroCard.
      final useWidget =
          _resolve(json, '/ui/pages/home/content/children/2') as Map;
      expect(useWidget['template'], equals('heroCard'));
    },
  );

  // ── w12 ───────────────────────────────────────────────────────────────────
  test('w12: renameStateKey renames state key and rewrites bindings', () async {
    final r = await d.renameStateKey(
      oldKey: 'counter',
      newKey: 'count',
      scope: 'page:home',
    );
    expect(r.success, isTrue, reason: r.message);

    final json = canonical.currentJson;
    final state = _resolve(json, '/ui/pages/home/state') as Map;
    expect(state.containsKey('counter'), isFalse);
    expect(state.containsKey('count'), isTrue);

    // The text content binding must be rewritten.
    final textContent =
        _resolve(json, '/ui/pages/home/content/children/0/content') as String;
    expect(textContent, contains('state.count'));
    expect(textContent, isNot(contains('state.counter')));
  });

  // ── w13 ───────────────────────────────────────────────────────────────────
  test('w13: applyLayoutPreset hero writes content to canonical', () async {
    final r = await d.applyLayoutPreset(pageId: 'home', kind: 'hero');
    expect(r.success, isTrue, reason: r.message);

    final content = _resolve(canonical.currentJson, '/ui/pages/home/content');
    expect(content, isA<Map>());
    final c = content as Map;
    expect(c['type'], equals('linear'));
    final children = c['children'] as List;
    // hero = displaySmall + bodyLarge + button (3 children).
    expect(children.length, equals(3));
    expect((children[2] as Map)['type'], equals('button'));
  });

  // ── w14 ───────────────────────────────────────────────────────────────────
  test(
    'w14: applyLayoutPreset form seeds state.fields and state.errors',
    () async {
      final r = await d.applyLayoutPreset(pageId: 'home', kind: 'form');
      expect(r.success, isTrue, reason: r.message);

      final state = _resolve(canonical.currentJson, '/ui/pages/home/state');
      expect(state, isA<Map>());
      final s = state as Map;
      expect(s.containsKey('fields'), isTrue);
      expect(s.containsKey('errors'), isTrue);
    },
  );

  // ── w15 ───────────────────────────────────────────────────────────────────
  test('w15: applyRecipe wrap_with_card wraps page content in card', () async {
    final r = await d.applyRecipe(
      name: 'wrap_with_card',
      args: <String, dynamic>{'path': '/ui/pages/home/content'},
    );
    expect(r.success, isTrue, reason: r.message);

    final content = _resolve(canonical.currentJson, '/ui/pages/home/content');
    expect((content as Map)['type'], equals('card'));
    // Original linear is now the card's child.
    expect((content['child'] as Map)['type'], equals('linear'));
  });

  // ── w16 ───────────────────────────────────────────────────────────────────
  test('w16: applyRecipe wrap_with_padding wraps content in box', () async {
    final r = await d.applyRecipe(
      name: 'wrap_with_padding',
      args: <String, dynamic>{'path': '/ui/pages/home/content', 'value': 32},
    );
    expect(r.success, isTrue, reason: r.message);

    final content = _resolve(canonical.currentJson, '/ui/pages/home/content');
    expect((content as Map)['type'], equals('box'));
    expect(content['padding'], equals(32));
  });

  // ── w17 ───────────────────────────────────────────────────────────────────
  test(
    'w17: applyRecipe add_floating_action sets floatingActionButton slot',
    () async {
      final r = await d.applyRecipe(
        name: 'add_floating_action',
        args: <String, dynamic>{'pageId': 'home', 'label': 'Add item'},
      );
      expect(r.success, isTrue, reason: r.message);

      final fab = _resolve(
        canonical.currentJson,
        '/ui/pages/home/floatingActionButton',
      );
      expect(fab, isA<Map>());
      expect((fab as Map)['type'], equals('floatingActionButton'));
      expect(fab['label'], equals('Add item'));
    },
  );

  // ── w18 ───────────────────────────────────────────────────────────────────
  test(
    'w18: applyRecipe wrap_with_safearea wraps page content in safeArea',
    () async {
      final r = await d.applyRecipe(
        name: 'wrap_with_safearea',
        args: <String, dynamic>{'pageId': 'home'},
      );
      expect(r.success, isTrue, reason: r.message);

      final content = _resolve(canonical.currentJson, '/ui/pages/home/content');
      expect((content as Map)['type'], equals('safeArea'));
      expect((content['child'] as Map)['type'], equals('linear'));
    },
  );

  // ── w19 ───────────────────────────────────────────────────────────────────
  test(
    'w19: applyRecipe add_loading_state seeds state key + conditional',
    () async {
      final r = await d.applyRecipe(
        name: 'add_loading_state',
        args: <String, dynamic>{'pageId': 'home', 'key': 'isLoading'},
      );
      expect(r.success, isTrue, reason: r.message);

      final json = canonical.currentJson;
      final content = _resolve(json, '/ui/pages/home/content') as Map;
      expect(content['type'], equals('conditional'));

      final stateKey = _resolve(json, '/ui/pages/home/state/isLoading');
      expect(stateKey, equals(false));
    },
  );

  // ── w20 ───────────────────────────────────────────────────────────────────
  test('w20: diffApply single add op mutates canonical', () async {
    final r = await d.diffApply(
      ops: <Map<String, dynamic>>[
        <String, dynamic>{
          'op': 'add',
          'path': '/ui/pages/home/content/testFlag',
          'value': true,
        },
      ],
    );
    expect(r.success, isTrue, reason: r.message);

    final flag = _resolve(
      canonical.currentJson,
      '/ui/pages/home/content/testFlag',
    );
    expect(flag, isTrue);
  });

  // ── w21 ───────────────────────────────────────────────────────────────────
  test('w21: diffApply multi-op writes multiple paths in one call', () async {
    final r = await d.diffApply(
      ops: <Map<String, dynamic>>[
        <String, dynamic>{
          'op': 'add',
          'path': '/ui/pages/home/content/alpha',
          'value': 1,
        },
        <String, dynamic>{
          'op': 'add',
          'path': '/ui/pages/home/content/beta',
          'value': 2,
        },
      ],
    );
    expect(r.success, isTrue, reason: r.message);

    final json = canonical.currentJson;
    expect(_resolve(json, '/ui/pages/home/content/alpha'), equals(1));
    expect(_resolve(json, '/ui/pages/home/content/beta'), equals(2));
  });

  // ── w22 ───────────────────────────────────────────────────────────────────
  test('w22: applyThemePreset writes /ui/theme with seed color', () async {
    final r = await d.applyThemePreset(seedColor: '#3F51B5', mode: 'light');
    expect(r.success, isTrue, reason: r.message);

    final theme = _resolve(canonical.currentJson, '/ui/theme') as Map;
    expect(theme['mode'], equals('light'));
    final seedColor = _resolve(canonical.currentJson, '/ui/theme/color/seed');
    expect(seedColor, equals('#3F51B5'));
  });

  // ── w23 ───────────────────────────────────────────────────────────────────
  test('w23: pageCreate creates page + route entries', () async {
    final r = await d.pageCreate(id: 'profile', title: 'Profile Page');
    expect(r.success, isTrue, reason: r.message);

    final json = canonical.currentJson;
    final pages = _resolve(json, '/ui/pages') as Map;
    expect(pages.containsKey('profile'), isTrue);
    expect((pages['profile'] as Map)['title'], equals('Profile Page'));

    final routes = _resolve(json, '/ui/routes') as Map;
    expect(routes.containsKey('/profile'), isTrue);
    expect(routes['/profile'], equals('profile'));
  });

  // ── w24 ───────────────────────────────────────────────────────────────────
  test(
    'w24: pageCreate with home:true sets initialRoute when missing',
    () async {
      // First clear initialRoute so pageCreate can set it.
      await canonical.applyAtomic(
        CanonicalPatch(
          layer: LayerId.appStructure,
          ops: <PatchOp>[PatchOp(op: 'remove', path: '/ui/initialRoute')],
          originator: const UserOriginator(),
        ),
      );

      final r = await d.pageCreate(id: 'landing', home: true);
      expect(r.success, isTrue, reason: r.message);

      final initialRoute = _resolve(canonical.currentJson, '/ui/initialRoute');
      expect(initialRoute, equals('/landing'));
    },
  );

  // ── w25 ───────────────────────────────────────────────────────────────────
  test(
    'w25: extractToTemplate creates template + replaces with use-widget',
    () async {
      final r = await d.extractToTemplate(
        widgetPath: '/ui/pages/home/content/children/0',
        newTemplateId: 'CounterText',
      );
      expect(r.success, isTrue, reason: r.message);

      final json = canonical.currentJson;
      // Template must exist.
      final templates = _resolve(json, '/ui/templates') as Map;
      expect(templates.containsKey('CounterText'), isTrue);
      final tpl = templates['CounterText'] as Map;
      expect(tpl['type'], equals('template'));

      // Original slot is now a use-widget.
      final slot = _resolve(json, '/ui/pages/home/content/children/0') as Map;
      expect(slot['type'], equals('use'));
      expect(slot['template'], equals('CounterText'));
    },
  );

  // ── w26 ───────────────────────────────────────────────────────────────────
  test('w26: i18nLocaleAdd writes locale into /ui/i18n/locales', () async {
    final r = await d.i18nLocaleAdd(tag: 'ko', setAsDefault: true);
    expect(r.success, isTrue, reason: r.message);

    final locales = _resolve(canonical.currentJson, '/ui/i18n/locales') as List;
    expect(locales, contains('ko'));
    final def = _resolve(canonical.currentJson, '/ui/i18n/defaultLocale');
    expect(def, equals('ko'));
  });

  // ── w27 ───────────────────────────────────────────────────────────────────
  test('w27: i18nLocaleRemove removes locale from list', () async {
    // First add locales.
    await d.i18nLocaleAdd(tag: 'en');
    await d.i18nLocaleAdd(tag: 'fr');

    final r = await d.i18nLocaleRemove(tag: 'en');
    expect(r.success, isTrue, reason: r.message);

    final locales = _resolve(canonical.currentJson, '/ui/i18n/locales') as List;
    expect(locales, isNot(contains('en')));
    expect(locales, contains('fr'));
  });

  // ── w28 ───────────────────────────────────────────────────────────────────
  test(
    'w28: i18nTextSet writes string under /ui/i18n/text/locale/key',
    () async {
      final r = await d.i18nTextSet(
        locale: 'en',
        key: 'greet',
        value: 'Hello!',
      );
      expect(r.success, isTrue, reason: r.message);

      final text = _resolve(canonical.currentJson, '/ui/i18n/text/en/greet');
      expect(text, equals('Hello!'));
    },
  );

  // ── w29 ───────────────────────────────────────────────────────────────────
  test('w29: i18nPluralizationSet writes pluralization map', () async {
    final r = await d.i18nPluralizationSet(
      locale: 'en',
      key: 'itemCount',
      forms: <String, dynamic>{
        'one': '{{count}} item',
        'other': '{{count}} items',
      },
    );
    expect(r.success, isTrue, reason: r.message);

    final forms =
        _resolve(canonical.currentJson, '/ui/i18n/pluralization/en/itemCount')
            as Map;
    expect(forms['one'], equals('{{count}} item'));
    expect(forms['other'], equals('{{count}} items'));
  });

  // ── w30 ───────────────────────────────────────────────────────────────────
  test('w30: i18nTextDirectionSet writes rtl for arabic locale', () async {
    final r = await d.i18nTextDirectionSet(locale: 'ar', direction: 'rtl');
    expect(r.success, isTrue, reason: r.message);

    final dir = _resolve(canonical.currentJson, '/ui/i18n/textDirection/ar');
    expect(dir, equals('rtl'));
  });

  // ── w31 ───────────────────────────────────────────────────────────────────
  test(
    'w31: themePresetSet writes preset value under /ui/theme/preset',
    () async {
      final r = await d.themePresetSet(preset: 'warm');
      expect(r.success, isTrue, reason: r.message);

      final preset = _resolve(canonical.currentJson, '/ui/theme/preset');
      expect(preset, equals('warm'));
    },
  );

  // ── w32 ───────────────────────────────────────────────────────────────────
  test(
    'w32: themeFontSet writes font entry under /ui/theme/fonts/<family>',
    () async {
      final r = await d.themeFontSet(
        family: 'Roboto',
        fallbacks: <String>['sans-serif'],
      );
      expect(r.success, isTrue, reason: r.message);

      final font =
          _resolve(canonical.currentJson, '/ui/theme/fonts/Roboto') as Map;
      expect(font.containsKey('fallbacks'), isTrue);
      expect((font['fallbacks'] as List), contains('sans-serif'));
    },
  );

  // ── w33 ───────────────────────────────────────────────────────────────────
  test(
    'w33: serviceSet (entry form) writes service under /ui/services',
    () async {
      final r = await d.serviceSet(
        name: 'weather',
        entry: <String, dynamic>{
          'kind': 'polling',
          'interval': 60,
          'tool': 'weather.fetch',
          'binding': 'weatherData',
        },
      );
      expect(r.success, isTrue, reason: r.message);

      final svc =
          _resolve(canonical.currentJson, '/ui/services/weather') as Map;
      expect(svc['kind'], equals('polling'));
      expect(svc['interval'], equals(60));
    },
  );

  // ── w34 ───────────────────────────────────────────────────────────────────
  test('w34: renameRoute moves route key and updates initialRoute', () async {
    final r = await d.renameRoute(oldPath: '/home', newPath: '/start');
    expect(r.success, isTrue, reason: r.message);

    final json = canonical.currentJson;
    final routes = _resolve(json, '/ui/routes') as Map;
    expect(routes.containsKey('/home'), isFalse);
    expect(routes.containsKey('/start'), isTrue);

    final initialRoute = _resolve(json, '/ui/initialRoute');
    expect(initialRoute, equals('/start'));
  });

  // ── w35 ───────────────────────────────────────────────────────────────────
  test(
    'w35: templateLibraryAdd writes uri into /ui/templateLibraries list',
    () async {
      final r = await d.templateLibraryAdd(
        uri: 'https://example.com/lib.json',
        version: '1.0',
      );
      expect(r.success, isTrue, reason: r.message);

      final list =
          _resolve(canonical.currentJson, '/ui/templateLibraries') as List;
      expect(list.length, equals(1));
      final entry = list[0] as Map;
      expect(entry['uri'], equals('https://example.com/lib.json'));
      expect(entry['version'], equals('1.0'));
    },
  );

  // ── w36 ───────────────────────────────────────────────────────────────────
  test('w36: hash changes after a write op', () async {
    final before = await canonical.hash();
    await d.setProperty(
      path: '/ui/pages/home/content',
      key: 'hashCheckFlag',
      value: 'changed',
    );
    final after = await canonical.hash();
    expect(after, isNot(equals(before)));
  });
}
