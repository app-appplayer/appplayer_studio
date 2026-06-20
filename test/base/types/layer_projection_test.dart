/// `LayerProjection.fromJson` derived views — routes / pages / lookup /
/// pathFor / layerForPath.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

void main() {
  group('LayerProjection.fromJson', () {
    test('empty json yields empty appStructure + empty pages', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{});
      expect(proj.appStructure.routes, isEmpty);
      expect(proj.pages, isEmpty);
    });

    test('parses routes from /ui/routes map', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'initialRoute': '/home',
          'routes': <String, dynamic>{
            '/home': 'ui://pages/home',
            '/about': 'ui://pages/about',
          },
        },
      });
      expect(proj.appStructure.routes, hasLength(2));
    });

    test('parses pages from /ui/pages map', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'ui': <String, dynamic>{
          'pages': <String, dynamic>{
            'home': <String, dynamic>{'type': 'page', 'title': 'Home'},
          },
        },
      });
      expect(proj.pages.keys, contains('home'));
    });

    test('lookup walks JSON pointer paths', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{
        'manifest': <String, dynamic>{
          'publisher': <String, dynamic>{'email': 'a@b.com'},
        },
      });
      expect(proj.lookup('/manifest/publisher/email'), 'a@b.com');
      expect(proj.lookup('/manifest/missing'), isNull);
    });

    test('pathFor returns the layer subpath; throws on LayerId.whole', () {
      final proj = LayerProjection.fromJson(<String, dynamic>{});
      // We don't assert exact strings (host-side convention) — only
      // that non-whole layers return a non-empty path, and `whole`
      // throws.
      for (final id in LayerId.values) {
        if (id == LayerId.whole) {
          expect(() => proj.pathFor(id), throwsA(anything));
        } else {
          expect(proj.pathFor(id), isNotEmpty);
        }
      }
    });
  });
}
