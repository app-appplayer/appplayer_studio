/// Unit tests for `app_builder/core/layer_projection.dart`.
///
/// The file is a re-export shim; the real logic is
/// `base/types/layer_projection.dart` (_LayerProjectionFactory). Tests
/// exercise all public getters, edge cases, and both route shapes
/// (map-form vs legacy list-form).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/app_builder/core/layer_projection.dart';
import 'package:appplayer_studio/base.dart' show LayerId;

void main() {
  // ── empty JSON ─────────────────────────────────────────────────────
  group('empty json', () {
    late LayerProjection proj;
    setUp(() => proj = LayerProjection.fromJson(<String, dynamic>{}));

    test('appStructure.routes is empty', () {
      expect(proj.appStructure.routes, isEmpty);
    });

    test('appStructure.permissions is empty', () {
      expect(proj.appStructure.permissions, isEmpty);
    });

    test('appStructure.background is null', () {
      expect(proj.appStructure.background, isNull);
    });

    test('appStructure.entryPageId is null', () {
      expect(proj.appStructure.entryPageId, isNull);
    });

    test('theme.raw is empty', () {
      expect(proj.theme.raw, isEmpty);
    });

    test('components.templates is empty', () {
      expect(proj.components.templates, isEmpty);
    });

    test('dashboard is null', () {
      expect(proj.dashboard, isNull);
    });

    test('navigation is null', () {
      expect(proj.navigation, isNull);
    });

    test('assets.entries is empty', () {
      expect(proj.assets.entries, isEmpty);
    });

    test('assets.raw is empty', () {
      expect(proj.assets.raw, isEmpty);
    });

    test('pages is empty', () {
      expect(proj.pages, isEmpty);
    });

    test('rawJson is the original map', () {
      expect(proj.rawJson, isEmpty);
    });
  });

  // ── routes — map form ──────────────────────────────────────────────
  group('routes map-form parsing', () {
    test('parses string uri routes with ui://pages/ prefix', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'routes': <String, dynamic>{
            '/home': 'ui://pages/home',
            '/about': 'ui://pages/about',
          },
        },
      });
      expect(proj.appStructure.routes, hasLength(2));
      final home = proj.appStructure.routes.firstWhere(
        (r) => r.path == '/home',
      );
      expect(home.pageId, 'home');
      final about = proj.appStructure.routes.firstWhere(
        (r) => r.path == '/about',
      );
      expect(about.pageId, 'about');
    });

    test('parses string uri routes with plain ui:// prefix', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'routes': <String, dynamic>{'/splash': 'ui://splash'},
        },
      });
      final splash = proj.appStructure.routes.firstWhere(
        (r) => r.path == '/splash',
      );
      expect(splash.pageId, 'splash');
    });

    test('parses non-uri string routes verbatim', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'routes': <String, dynamic>{'/raw': 'raw_page_id'},
        },
      });
      expect(proj.appStructure.routes.first.pageId, 'raw_page_id');
    });

    test('parses map-value route with id key', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'routes': <String, dynamic>{
            '/detail': <String, dynamic>{'id': 'detailPage', 'type': 'page'},
          },
        },
      });
      expect(proj.appStructure.routes.first.pageId, 'detailPage');
    });

    test('map-value route without id yields empty pageId', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'routes': <String, dynamic>{
            '/no-id': <String, dynamic>{'type': 'page'},
          },
        },
      });
      expect(proj.appStructure.routes.first.pageId, '');
    });
  });

  // ── routes — legacy list form ──────────────────────────────────────
  group('routes legacy list-form parsing', () {
    test('parses list of route objects', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'routes': <dynamic>[
            <String, dynamic>{'id': 'r1', 'path': '/r1', 'pageId': 'p1'},
            <String, dynamic>{'id': 'r2', 'path': '/r2', 'pageId': 'p2'},
          ],
        },
      });
      expect(proj.appStructure.routes, hasLength(2));
      expect(proj.appStructure.routes[0].id, 'r1');
      expect(proj.appStructure.routes[0].path, '/r1');
      expect(proj.appStructure.routes[0].pageId, 'p1');
    });

    test('skips non-Map items in list', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'routes': <dynamic>[
            'not-a-map',
            <String, dynamic>{'id': 'ok', 'path': '/ok', 'pageId': 'ok_page'},
          ],
        },
      });
      // 'not-a-map' is skipped; only the Map entry is parsed.
      expect(proj.appStructure.routes, hasLength(1));
      expect(proj.appStructure.routes.first.id, 'ok');
    });
  });

  // ── entryPageId resolution ─────────────────────────────────────────
  group('entryPageId', () {
    test('resolves from initialRoute + routes uri', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'initialRoute': '/home',
          'routes': <String, dynamic>{'/home': 'ui://pages/home_page'},
        },
      });
      expect(proj.appStructure.entryPageId, 'home_page');
    });

    test('resolves from initialRoute + map-value route id', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'initialRoute': '/x',
          'routes': <String, dynamic>{
            '/x': <String, dynamic>{'id': 'xPage'},
          },
        },
      });
      expect(proj.appStructure.entryPageId, 'xPage');
    });

    test('falls back to initialRoute string when no matching route', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'initialRoute': '/fallback',
          'routes': <String, dynamic>{},
        },
      });
      expect(proj.appStructure.entryPageId, '/fallback');
    });

    test('null when initialRoute is absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'routes': <String, dynamic>{'/home': 'ui://pages/home'},
        },
      });
      expect(proj.appStructure.entryPageId, isNull);
    });
  });

  // ── permissions ────────────────────────────────────────────────────
  group('permissions parsing', () {
    test('parses string permission list', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'permissions': <dynamic>['camera', 'microphone'],
        },
      });
      expect(proj.appStructure.permissions, hasLength(2));
      expect(proj.appStructure.permissions[0].id, 'camera');
      expect(proj.appStructure.permissions[0].granted, isTrue);
    });

    test('parses map permission with granted flag', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'permissions': <dynamic>[
            <String, dynamic>{'id': 'storage', 'granted': false},
          ],
        },
      });
      expect(proj.appStructure.permissions.first.id, 'storage');
      expect(proj.appStructure.permissions.first.granted, isFalse);
    });

    test('empty permissions list when key absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{},
      });
      expect(proj.appStructure.permissions, isEmpty);
    });
  });

  // ── background policy ──────────────────────────────────────────────
  group('background policy', () {
    test('parses background.kind', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'background': <String, dynamic>{'kind': 'fetch'},
        },
      });
      expect(proj.appStructure.background, isNotNull);
      expect(proj.appStructure.background!.kind, 'fetch');
    });

    test('background is null when key absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{},
      });
      expect(proj.appStructure.background, isNull);
    });

    test('background is null when value is not a Map', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{'background': 'string-value'},
      });
      expect(proj.appStructure.background, isNull);
    });
  });

  // ── theme ──────────────────────────────────────────────────────────
  group('theme', () {
    test('wraps raw theme map', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'theme': <String, dynamic>{'primaryColor': '#FF0000'},
        },
      });
      expect(proj.theme.raw['primaryColor'], '#FF0000');
    });

    test('empty theme when ui.theme absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{},
      });
      expect(proj.theme.raw, isEmpty);
    });

    test('empty theme when ui section absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{});
      expect(proj.theme.raw, isEmpty);
    });
  });

  // ── components / templates ─────────────────────────────────────────
  group('components', () {
    test('parses templates map', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'templates': <String, dynamic>{
            'myCard': <String, dynamic>{'type': 'box'},
            'myLabel': <String, dynamic>{'type': 'text'},
          },
        },
      });
      expect(proj.components.templates, hasLength(2));
      expect(proj.components.templates['myCard'], isNotNull);
      expect(proj.components.templates['myLabel']!['type'], 'text');
    });

    test('skips non-Map template values', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'templates': <String, dynamic>{
            'good': <String, dynamic>{'type': 'box'},
            'bad': 'not-a-map',
          },
        },
      });
      expect(proj.components.templates, hasLength(1));
      expect(proj.components.templates.containsKey('bad'), isFalse);
    });

    test('empty components when templates absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{});
      expect(proj.components.templates, isEmpty);
    });
  });

  // ── dashboard ──────────────────────────────────────────────────────
  group('dashboard', () {
    test('parses dashboard block', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'dashboard': <String, dynamic>{
            'content': <String, dynamic>{'type': 'box'},
          },
        },
      });
      expect(proj.dashboard, isNotNull);
      expect(proj.dashboard!.raw['content'], isNotNull);
    });

    test('null when dashboard absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{},
      });
      expect(proj.dashboard, isNull);
    });

    test('null when dashboard is not a Map', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{'dashboard': 42},
      });
      expect(proj.dashboard, isNull);
    });
  });

  // ── navigation ─────────────────────────────────────────────────────
  group('navigation', () {
    test('parses navigation block', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'navigation': <String, dynamic>{'type': 'bottomBar'},
        },
      });
      expect(proj.navigation, isNotNull);
      expect(proj.navigation!.raw['type'], 'bottomBar');
    });

    test('null when navigation absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{},
      });
      expect(proj.navigation, isNull);
    });

    test('null when navigation is non-Map', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{'navigation': true},
      });
      expect(proj.navigation, isNull);
    });
  });

  // ── assets ─────────────────────────────────────────────────────────
  group('assets', () {
    test('surfaces asset entries list', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'manifest': <String, dynamic>{
          'assets': <String, dynamic>{
            'schemaVersion': '1.0',
            'assets': <dynamic>[
              <String, dynamic>{'id': 'logo', 'path': 'assets/logo.png'},
              <String, dynamic>{'id': 'bg', 'path': 'assets/bg.jpg'},
            ],
          },
        },
      });
      expect(proj.assets.entries, hasLength(2));
      expect(proj.assets.entries.first['id'], 'logo');
      expect(proj.assets.raw['schemaVersion'], '1.0');
    });

    test('empty entries when manifest.assets absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{});
      expect(proj.assets.entries, isEmpty);
      expect(proj.assets.raw, isEmpty);
    });

    test('empty entries when assets.assets is not a list', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'manifest': <String, dynamic>{
          'assets': <String, dynamic>{'assets': 'wrong'},
        },
      });
      expect(proj.assets.entries, isEmpty);
    });

    test('skips non-Map entries in asset list', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'manifest': <String, dynamic>{
          'assets': <String, dynamic>{
            'assets': <dynamic>[
              'str',
              <String, dynamic>{'id': 'x'},
            ],
          },
        },
      });
      expect(proj.assets.entries, hasLength(1));
      expect(proj.assets.entries.first['id'], 'x');
    });
  });

  // ── pages ──────────────────────────────────────────────────────────
  group('pages', () {
    test('parses pages from ui.pages map', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'home': <String, dynamic>{'type': 'page', 'title': 'Home'},
          },
        },
      });
      expect(proj.pages, hasLength(1));
      expect(proj.pages.containsKey('home'), isTrue);
      expect(proj.pages['home']!.id, 'home');
      expect(proj.pages['home']!.raw['title'], 'Home');
    });

    test('also picks up inline map-value routes as page slices', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'routes': <String, dynamic>{
            '/detail': <String, dynamic>{'type': 'page', 'title': 'Detail'},
          },
        },
      });
      expect(proj.pages.containsKey('/detail'), isTrue);
    });

    test('pages.map entry takes precedence over same-key route entry', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'home': <String, dynamic>{'title': 'From pages'},
          },
          'routes': <String, dynamic>{
            'home': <String, dynamic>{'title': 'From routes'},
          },
        },
      });
      // pages map is built first; route entry with same key is skipped.
      expect(proj.pages['home']!.raw['title'], 'From pages');
    });

    test('empty pages when ui absent', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{});
      expect(proj.pages, isEmpty);
    });

    test('skips non-Map values in pages map', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'good': <String, dynamic>{'type': 'page'},
            'bad': 'not-a-map',
          },
        },
      });
      expect(proj.pages.containsKey('good'), isTrue);
      expect(proj.pages.containsKey('bad'), isFalse);
    });
  });

  // ── lookup — JSON Pointer ──────────────────────────────────────────
  group('lookup', () {
    late LayerProjection proj;
    setUp(() {
      proj = LayerProjection.fromJson(<String, dynamic>{
        'manifest': <String, dynamic>{
          'publisher': <String, dynamic>{
            'email': 'hello@example.com',
            'nested': <String, dynamic>{'deep': 99},
          },
        },
        'ui': <String, dynamic>{
          'title': 'My App',
          'list': <dynamic>[10, 20, 30],
        },
      });
    });

    test('resolves two-level path', () {
      expect(proj.lookup('/manifest/publisher/email'), 'hello@example.com');
    });

    test('resolves three-level path', () {
      expect(proj.lookup('/manifest/publisher/nested/deep'), 99);
    });

    test('resolves shallow path', () {
      expect(proj.lookup('/ui/title'), 'My App');
    });

    test('returns null for missing segment', () {
      expect(proj.lookup('/manifest/missing'), isNull);
    });

    test('returns null for path into non-container', () {
      expect(proj.lookup('/ui/title/sub'), isNull);
    });

    test('resolves list item by index', () {
      expect(proj.lookup('/ui/list/0'), 10);
      expect(proj.lookup('/ui/list/2'), 30);
    });

    test('returns null for out-of-bounds list index', () {
      expect(proj.lookup('/ui/list/99'), isNull);
    });

    test('returns null for non-numeric segment into a list', () {
      expect(proj.lookup('/ui/list/x'), isNull);
    });

    test('leading slash is normalised — no empty first segment', () {
      // "/manifest" must work (leading slash stripped by split).
      expect(proj.lookup('/ui'), isA<Map>());
    });
  });

  // ── pathFor ────────────────────────────────────────────────────────
  group('pathFor', () {
    final proj = LayerProjection.fromJson(<String, dynamic>{});

    test('appStructure → ui/app.json', () {
      expect(proj.pathFor(LayerId.appStructure), 'ui/app.json');
    });

    test('theme → ui/app.json', () {
      expect(proj.pathFor(LayerId.theme), 'ui/app.json');
    });

    test('components → ui/app.json', () {
      expect(proj.pathFor(LayerId.components), 'ui/app.json');
    });

    test('navigation → ui/app.json', () {
      expect(proj.pathFor(LayerId.navigation), 'ui/app.json');
    });

    test('pages → ui/pages/', () {
      expect(proj.pathFor(LayerId.pages), 'ui/pages/');
    });

    test('dashboard → ui/pages/', () {
      expect(proj.pathFor(LayerId.dashboard), 'ui/pages/');
    });

    test('assets → manifest.json', () {
      expect(proj.pathFor(LayerId.assets), 'manifest.json');
    });

    test('knowledge → manifest.json', () {
      expect(proj.pathFor(LayerId.knowledge), 'manifest.json');
    });

    test('manifest → manifest.json', () {
      expect(proj.pathFor(LayerId.manifest), 'manifest.json');
    });

    test('tools → manifest.json', () {
      expect(proj.pathFor(LayerId.tools), 'manifest.json');
    });

    test('agents → manifest.json', () {
      expect(proj.pathFor(LayerId.agents), 'manifest.json');
    });

    test('whole throws UnsupportedError', () {
      expect(() => proj.pathFor(LayerId.whole), throwsUnsupportedError);
    });

    test('every non-whole layer returns a non-empty string', () {
      for (final id in LayerId.values) {
        if (id == LayerId.whole) continue;
        expect(proj.pathFor(id), isNotEmpty);
      }
    });
  });

  // ── layerForPath ───────────────────────────────────────────────────
  group('layerForPath', () {
    final proj = LayerProjection.fromJson(<String, dynamic>{});

    test('ui/app.json → appStructure', () {
      expect(proj.layerForPath('ui/app.json'), LayerId.appStructure);
    });

    test('ui/pages/home.json → pages', () {
      expect(proj.layerForPath('ui/pages/home.json'), LayerId.pages);
    });

    test('ui/pages/ prefix → pages', () {
      expect(proj.layerForPath('ui/pages/detail.json'), LayerId.pages);
    });

    test('unknown path → null', () {
      expect(proj.layerForPath('manifest.json'), isNull);
      expect(proj.layerForPath('unknown'), isNull);
    });
  });

  // ── rawJson pass-through ────────────────────────────────────────────
  group('rawJson', () {
    test('returns the same map that was passed in', () {
      final json = <String, dynamic>{
        'ui': <String, dynamic>{'title': 'x'},
      };
      final proj = LayerProjection.fromJson(json);
      expect(proj.rawJson, same(json));
    });
  });
}
