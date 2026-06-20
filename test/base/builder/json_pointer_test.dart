/// Unit coverage for `json_pointer.dart` — ptrSegments / ptrGet /
/// ptrSet / ptrRemove.
///
/// All paths are pure Dart with no Flutter dependency; the test does
/// not call any Flutter widget APIs.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

void main() {
  // ---------------------------------------------------------------------------
  // ptrSegments
  // ---------------------------------------------------------------------------
  group('ptrSegments', () {
    test('empty string returns empty list (root pointer)', () {
      expect(ptrSegments(''), isEmpty);
    });

    test('single segment', () {
      expect(ptrSegments('/foo'), <String>['foo']);
    });

    test('multi segment', () {
      expect(ptrSegments('/a/b/c'), <String>['a', 'b', 'c']);
    });

    test('~1 decoded to /', () {
      expect(ptrSegments('/a~1b'), <String>['a/b']);
    });

    test('~0 decoded to ~', () {
      expect(ptrSegments('/a~0b'), <String>['a~b']);
    });

    test('~0~1 decoded in order (tilde before slash)', () {
      expect(ptrSegments('/a~0~1b'), <String>['a~/b']);
    });

    test('missing leading / throws FormatException', () {
      expect(() => ptrSegments('no/slash'), throwsA(isA<FormatException>()));
    });
  });

  // ---------------------------------------------------------------------------
  // ptrGet
  // ---------------------------------------------------------------------------
  group('ptrGet', () {
    test('root pointer returns the root object', () {
      final m = <String, dynamic>{'a': 1};
      expect(ptrGet(m, ''), same(m));
    });

    test('walks a nested map', () {
      final doc = <String, dynamic>{
        'ui': <String, dynamic>{'theme': 'dark'},
      };
      expect(ptrGet(doc, '/ui/theme'), 'dark');
    });

    test('walks a list by index', () {
      final doc = <String, dynamic>{
        'items': <dynamic>[10, 20, 30],
      };
      expect(ptrGet(doc, '/items/1'), 20);
    });

    test('list index OOB throws FormatException', () {
      final doc = <String, dynamic>{
        'items': <dynamic>[1, 2],
      };
      expect(() => ptrGet(doc, '/items/5'), throwsA(isA<FormatException>()));
    });

    test('traversal into non-collection throws FormatException', () {
      final doc = <String, dynamic>{'x': 42};
      expect(() => ptrGet(doc, '/x/sub'), throwsA(isA<FormatException>()));
    });

    test('missing map key returns null', () {
      final doc = <String, dynamic>{'a': 1};
      expect(ptrGet(doc, '/missing'), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // ptrSet — map targets
  // ---------------------------------------------------------------------------
  group('ptrSet map', () {
    test('set new key on root map', () {
      final doc = <String, dynamic>{'a': 1};
      ptrSet(doc, '/b', 99, insert: false);
      expect(doc['b'], 99);
    });

    test('replace existing value', () {
      final doc = <String, dynamic>{'a': 1};
      ptrSet(doc, '/a', 42, insert: false);
      expect(doc['a'], 42);
    });

    test('set nested key creates/replaces', () {
      final doc = <String, dynamic>{
        'ui': <String, dynamic>{'theme': 'light'},
      };
      ptrSet(doc, '/ui/theme', 'dark', insert: false);
      expect((doc['ui'] as Map)['theme'], 'dark');
    });

    test('empty pointer (root) throws FormatException', () {
      final doc = <String, dynamic>{};
      expect(
        () => ptrSet(doc, '', 1, insert: false),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // ptrSet — list targets
  // ---------------------------------------------------------------------------
  group('ptrSet list', () {
    test('append via dash segment', () {
      final doc = <String, dynamic>{
        'items': <dynamic>[1, 2],
      };
      ptrSet(doc, '/items/-', 3, insert: false);
      expect((doc['items'] as List), <dynamic>[1, 2, 3]);
    });

    test('insert at index (insert=true)', () {
      final doc = <String, dynamic>{
        'items': <dynamic>[1, 3],
      };
      ptrSet(doc, '/items/1', 2, insert: true);
      expect((doc['items'] as List), <dynamic>[1, 2, 3]);
    });

    test('replace at index (insert=false)', () {
      final doc = <String, dynamic>{
        'items': <dynamic>[1, 9, 3],
      };
      ptrSet(doc, '/items/1', 2, insert: false);
      expect((doc['items'] as List), <dynamic>[1, 2, 3]);
    });

    test('insert OOB throws FormatException', () {
      final doc = <String, dynamic>{
        'items': <dynamic>[1],
      };
      expect(
        () => ptrSet(doc, '/items/5', 99, insert: true),
        throwsA(isA<FormatException>()),
      );
    });

    test('replace OOB throws FormatException', () {
      final doc = <String, dynamic>{
        'items': <dynamic>[1],
      };
      expect(
        () => ptrSet(doc, '/items/5', 99, insert: false),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // ptrRemove
  // ---------------------------------------------------------------------------
  group('ptrRemove', () {
    test('removes key from map', () {
      final doc = <String, dynamic>{'a': 1, 'b': 2};
      ptrRemove(doc, '/a');
      expect(doc.containsKey('a'), isFalse);
      expect(doc['b'], 2);
    });

    test('removes element from list by index', () {
      final doc = <String, dynamic>{
        'items': <dynamic>[10, 20, 30],
      };
      ptrRemove(doc, '/items/1');
      expect((doc['items'] as List), <dynamic>[10, 30]);
    });

    test('empty pointer throws FormatException', () {
      final doc = <String, dynamic>{'a': 1};
      expect(() => ptrRemove(doc, ''), throwsA(isA<FormatException>()));
    });

    test('list index OOB throws FormatException', () {
      final doc = <String, dynamic>{
        'items': <dynamic>[1],
      };
      expect(() => ptrRemove(doc, '/items/9'), throwsA(isA<FormatException>()));
    });

    test('removes nested map key', () {
      final doc = <String, dynamic>{
        'ui': <String, dynamic>{'theme': 'dark', 'lang': 'en'},
      };
      ptrRemove(doc, '/ui/theme');
      final ui = doc['ui'] as Map;
      expect(ui.containsKey('theme'), isFalse);
      expect(ui['lang'], 'en');
    });
  });
}
