/// Extended `LayerProjection.fromJson` coverage — branches not
/// exercised by `layer_projection_test.dart`:
///   - layerForPath reverse lookup
///   - legacy routes list form
///   - permissions, background, entryPageId
///   - dashboard slice, navigation slice
///   - asset slice (with entries)
///   - components from ui.templates
///   - lookup into lists by index
///   - pathFor each non-whole layer value
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

void main() {
  group('LayerProjection.fromJson extended', () {
    // -----------------------------------------------------------------------
    // layerForPath
    // -----------------------------------------------------------------------
    test('layerForPath("ui/app.json") → appStructure', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{});
      expect(proj.layerForPath('ui/app.json'), LayerId.appStructure);
    });

    test('layerForPath("ui/pages/home.json") → pages', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{});
      expect(proj.layerForPath('ui/pages/home.json'), LayerId.pages);
    });

    test('layerForPath returns null for unrecognised path', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{});
      expect(proj.layerForPath('manifest.json'), isNull);
    });

    // -----------------------------------------------------------------------
    // pathFor — every non-whole layer returns a non-empty string
    // -----------------------------------------------------------------------
    test('pathFor each layer returns expected path', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{});
      const uiLayers = <LayerId>[
        LayerId.appStructure,
        LayerId.theme,
        LayerId.components,
        LayerId.navigation,
      ];
      for (final id in uiLayers) {
        expect(
          proj.pathFor(id),
          'ui/app.json',
          reason: '$id should map to ui/app.json',
        );
      }
      const pageLayers = <LayerId>[LayerId.pages, LayerId.dashboard];
      for (final id in pageLayers) {
        expect(
          proj.pathFor(id),
          'ui/pages/',
          reason: '$id should map to ui/pages/',
        );
      }
      const manifestLayers = <LayerId>[
        LayerId.assets,
        LayerId.knowledge,
        LayerId.manifest,
        LayerId.tools,
        LayerId.agents,
      ];
      for (final id in manifestLayers) {
        expect(
          proj.pathFor(id),
          'manifest.json',
          reason: '$id should map to manifest.json',
        );
      }
    });

    // -----------------------------------------------------------------------
    // Legacy list form of routes
    // -----------------------------------------------------------------------
    test('parses legacy routes list form', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'routes': <dynamic>[
            <String, dynamic>{'id': 'r1', 'path': '/home', 'pageId': 'home'},
          ],
        },
      });
      expect(proj.appStructure.routes, hasLength(1));
      final route = proj.appStructure.routes.first;
      expect(route.id, 'r1');
      expect(route.path, '/home');
      expect(route.pageId, 'home');
    });

    // -----------------------------------------------------------------------
    // entryPageId — from initialRoute + routes map
    // -----------------------------------------------------------------------
    test('entryPageId resolved from initialRoute + uri route', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'initialRoute': '/home',
          'routes': <String, dynamic>{'/home': 'ui://pages/home'},
        },
      });
      expect(proj.appStructure.entryPageId, 'home');
    });

    test('entryPageId falls back to initialRoute string if route missing', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'initialRoute': '/fallback',
          'routes': <String, dynamic>{},
        },
      });
      expect(proj.appStructure.entryPageId, '/fallback');
    });

    // -----------------------------------------------------------------------
    // permissions
    // -----------------------------------------------------------------------
    test('parses permissions list (string entries)', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'permissions': <dynamic>['camera', 'microphone'],
        },
      });
      final perms = proj.appStructure.permissions;
      expect(perms, hasLength(2));
      expect(
        perms.map((p) => p.id),
        containsAll(<String>['camera', 'microphone']),
      );
      expect(perms.every((p) => p.granted), isTrue);
    });

    test('parses permissions list (map entries with granted:false)', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'permissions': <dynamic>[
            <String, dynamic>{'id': 'gps', 'granted': false},
          ],
        },
      });
      final perm = proj.appStructure.permissions.first;
      expect(perm.id, 'gps');
      expect(perm.granted, isFalse);
    });

    // -----------------------------------------------------------------------
    // background
    // -----------------------------------------------------------------------
    test('background policy parsed from ui.background map', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'background': <String, dynamic>{'kind': 'transparent'},
        },
      });
      expect(proj.appStructure.background?.kind, 'transparent');
    });

    test('background is null when not a Map', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{'background': 'none'},
      });
      expect(proj.appStructure.background, isNull);
    });

    // -----------------------------------------------------------------------
    // dashboard slice
    // -----------------------------------------------------------------------
    test('dashboard returns DashboardSlice when ui.dashboard present', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'dashboard': <String, dynamic>{'content': <String, dynamic>{}},
        },
      });
      expect(proj.dashboard, isA<DashboardSlice>());
      expect(proj.dashboard!.raw.containsKey('content'), isTrue);
    });

    test('dashboard returns null when absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{},
      });
      expect(proj.dashboard, isNull);
    });

    // -----------------------------------------------------------------------
    // navigation slice
    // -----------------------------------------------------------------------
    test('navigation returns NavigationSlice when ui.navigation present', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'navigation': <String, dynamic>{'type': 'bottomBar'},
        },
      });
      expect(proj.navigation, isA<NavigationSlice>());
      expect(proj.navigation!.raw['type'], 'bottomBar');
    });

    test('navigation returns null when absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{});
      expect(proj.navigation, isNull);
    });

    // -----------------------------------------------------------------------
    // assets slice
    // -----------------------------------------------------------------------
    test('asset slice carries entries from manifest.assets.assets[]', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'manifest': <String, dynamic>{
          'assets': <String, dynamic>{
            'schemaVersion': '1.0',
            'assets': <dynamic>[
              <String, dynamic>{
                'id': 'icon_home',
                'type': 'icon',
                'path': 'assets/icons/home.svg',
              },
            ],
          },
        },
      });
      final slice = proj.assets;
      expect(slice.raw.containsKey('schemaVersion'), isTrue);
      expect(slice.entries, hasLength(1));
      expect(slice.entries.first['id'], 'icon_home');
    });

    test('asset slice is empty when manifest.assets absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{});
      expect(proj.assets.entries, isEmpty);
      expect(proj.assets.raw, isEmpty);
    });

    // -----------------------------------------------------------------------
    // components from ui.templates
    // -----------------------------------------------------------------------
    test('components.templates populated from ui.templates', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'templates': <String, dynamic>{
            'MyButton': <String, dynamic>{'type': 'button', 'label': 'Click'},
          },
        },
      });
      expect(proj.components.templates.containsKey('MyButton'), isTrue);
      expect(proj.components.templates['MyButton']?['type'], 'button');
    });

    test('components is empty when ui.templates absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{},
      });
      expect(proj.components.templates, isEmpty);
    });

    // -----------------------------------------------------------------------
    // lookup into lists by index
    // -----------------------------------------------------------------------
    test('lookup resolves list element by numeric index segment', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{'name': 'first'},
          <String, dynamic>{'name': 'second'},
        ],
      });
      expect(proj.lookup('/items/0/name'), 'first');
      expect(proj.lookup('/items/1/name'), 'second');
    });

    test('lookup returns null for OOB list index', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'list': <dynamic>[1, 2],
      });
      expect(proj.lookup('/list/5'), isNull);
    });

    // -----------------------------------------------------------------------
    // rawJson passthrough
    // -----------------------------------------------------------------------
    test('rawJson returns the original map', () {
      final original = <String, dynamic>{'custom': 'field'};
      final proj = LayerProjection.fromJson(original);
      expect(proj.rawJson, same(original));
    });
  });
}
