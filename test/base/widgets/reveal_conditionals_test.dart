/// [revealConditionalsForDesign] — the DESIGN canvas must show (and keep
/// click-selectable at the real canonical path) content the runtime
/// would hide: `conditional` branches and binding-driven empty `list`s.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/widgets/preview_mcp_ui.dart';

void main() {
  test('rc1: conditional keeps its node, condition forced true, '
      'then identity preserved', () {
    final then = <String, dynamic>{'type': 'text', 'value': 'Report'};
    final page = <String, dynamic>{
      'type': 'page',
      'content': <String, dynamic>{
        'type': 'linear',
        'children': <dynamic>[
          <String, dynamic>{'type': 'button', 'label': 'Go'},
          <String, dynamic>{
            'type': 'conditional',
            'condition': '{{items}}',
            'then': then,
          },
        ],
      },
    };
    final out = revealConditionalsForDesign(page) as Map<String, dynamic>;
    final cond = ((out['content'] as Map)['children'] as List)[1] as Map;
    expect(cond['type'], 'conditional',
        reason: 'node must stay so tap paths keep the /then segment');
    expect(cond['condition'], true, reason: 'branch forced visible');
    expect(identical(cond['then'], then), isTrue,
        reason: 'then identity preserved for inspect-select');
    // Original untouched.
    expect(
      (((page['content'] as Map)['children'] as List)[1]
          as Map)['condition'],
      '{{items}}',
    );
  });

  test('rc2: no conditional/list → identical tree (zero copy)', () {
    final page = <String, dynamic>{
      'type': 'page',
      'content': <String, dynamic>{'type': 'text', 'value': 'x'},
    };
    expect(identical(revealConditionalsForDesign(page), page), isTrue);
  });

  test('rc3: nested conditional inside then is also forced visible', () {
    final node = <String, dynamic>{
      'type': 'conditional',
      'condition': '{{a}}',
      'then': <String, dynamic>{
        'type': 'conditional',
        'condition': '{{b}}',
        'then': <String, dynamic>{'type': 'text', 'value': 'deep'},
      },
    };
    final out = revealConditionalsForDesign(node) as Map<String, dynamic>;
    expect(out['condition'], true);
    expect((out['then'] as Map)['condition'], true);
  });

  test('rc4: binding-list gets one sample item echoing template fields',
      () {
    final tpl = <String, dynamic>{
      'type': 'linear',
      'children': <dynamic>[
        <String, dynamic>{'type': 'text', 'value': '{{item.name}}'},
        <String, dynamic>{'type': 'text', 'value': '{{item.amount}}'},
      ],
    };
    final list = <String, dynamic>{
      'type': 'list',
      'items': '{{items}}',
      'itemTemplate': tpl,
    };
    final out = revealConditionalsForDesign(list) as Map<String, dynamic>;
    final items = out['items'] as List;
    expect(items, hasLength(1), reason: 'one visible design row');
    expect(items.single, {'name': 'name', 'amount': 'amount'});
    expect(identical(out['itemTemplate'], tpl), isTrue,
        reason: 'template identity preserved for inspect-select');
    // Literal-items lists are untouched (already visible).
    final literal = <String, dynamic>{
      'type': 'list',
      'items': <dynamic>[{'name': 'a'}],
      'itemTemplate': tpl,
    };
    expect(identical(revealConditionalsForDesign(literal), literal), isTrue);
  });

  group('revealPageForDesign', () {
    Map<String, dynamic> row() => <String, dynamic>{
      'type': 'text',
      'value': '{{item.name}}',
    };

    test('rc5: a list bound to a state path keeps its binding; the sample '
        'row is that path\'s initial value', () {
      final tpl = row();
      final page = <String, dynamic>{
        'type': 'page',
        'state': <String, dynamic>{
          'initial': <String, dynamic>{'roster': <dynamic>[], 'title': 'Desk'},
        },
        'content': <String, dynamic>{
          'type': 'list',
          'items': '{{live.roster}}',
          'itemTemplate': tpl,
        },
      };
      final out = revealPageForDesign(page);
      final list = out['content'] as Map;
      expect(list['items'], '{{live.roster}}',
          reason: 'a tool response that fills the path must show real rows');
      expect(identical(list['itemTemplate'], tpl), isTrue);
      final initial = (out['state'] as Map)['initial'] as Map;
      expect(initial['live'], {
        'roster': [
          {'name': 'name'},
        ],
      });
      expect(initial['title'], 'Desk');
      expect(
        ((page['state'] as Map)['initial'] as Map).containsKey('live'),
        isFalse,
        reason: 'the canonical page is not modified',
      );
    });

    test('rc6: an empty initial list is seeded, authored rows are kept', () {
      Map<String, dynamic> pageWith(Object? roster) => <String, dynamic>{
        'type': 'page',
        'state': <String, dynamic>{
          'initial': <String, dynamic>{'roster': roster},
        },
        'content': <String, dynamic>{
          'type': 'list',
          'items': '{{roster}}',
          'itemTemplate': row(),
        },
      };
      final empty = revealPageForDesign(pageWith(<dynamic>[]));
      expect(((empty['state'] as Map)['initial'] as Map)['roster'], [
        {'name': 'name'},
      ]);
      final authored = pageWith(<dynamic>[
        {'name': 'Ava'},
      ]);
      expect(identical(revealPageForDesign(authored), authored), isTrue);
    });

    test('rc7: a page without state gets one; a list inside an item template '
        'still shows its sample in place', () {
      final nested = <String, dynamic>{
        'type': 'list',
        'items': '{{item.children}}',
        'itemTemplate': row(),
      };
      final page = <String, dynamic>{
        'type': 'page',
        'content': <String, dynamic>{
          'type': 'list',
          'items': '{{groups}}',
          'itemTemplate': <String, dynamic>{
            'type': 'linear',
            'children': <dynamic>[nested],
          },
        },
      };
      final out = revealPageForDesign(page);
      expect((out['content'] as Map)['items'], '{{groups}}');
      final groups =
          ((out['state'] as Map)['initial'] as Map)['groups'] as List;
      expect(groups, hasLength(1));
      final inner = (((out['content'] as Map)['itemTemplate'] as Map)
          ['children'] as List).single as Map;
      expect(inner['items'], [
        {'name': 'name'},
      ]);
      expect(page.containsKey('state'), isFalse);
    });

    test('rc8: an expression binding keeps the in-place sample', () {
      final page = <String, dynamic>{
        'type': 'page',
        'content': <String, dynamic>{
          'type': 'list',
          'items': '{{rows.length > 0 ? rows : []}}',
          'itemTemplate': row(),
        },
      };
      final out = revealPageForDesign(page);
      expect((out['content'] as Map)['items'], [
        {'name': 'name'},
      ]);
      expect(out.containsKey('state'), isFalse);
    });
  });
}
