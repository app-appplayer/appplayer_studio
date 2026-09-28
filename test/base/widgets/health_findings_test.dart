/// The Inspector's Health section counts every finding the health check
/// reports — spec, wiring and a11y — not a11y alone. It used to read
/// "all clear" while `health_check` failed on two undeclared tool calls.
library;

import 'package:appplayer_studio/src/base/widgets/properties_panel.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _health() => <String, dynamic>{
  'status': 'fail',
  'details': <String, dynamic>{
    'validation': <String, dynamic>{
      'specIssues': <Map<String, dynamic>>[
        {
          'level': 'error',
          'code': 'schema',
          'path': '/ui/theme/colors',
          'message': 'bad color',
        },
      ],
      'wiringIssues': <Map<String, dynamic>>[
        {
          'kind': 'undefined_tool_ref',
          'page': 'home',
          'tool': 'calculate',
          'message': 'page "home" calls tool "calculate"',
        },
        {'kind': 'tool_refs_unverified', 'message': 'no tool list'},
      ],
    },
    'a11y': <String, dynamic>{
      'findings': <Map<String, dynamic>>[
        {
          'severity': 'warn',
          'rule': 'icon.accessibleName',
          'path': '/ui/pages/home/content/child',
          'message': 'icon',
        },
      ],
    },
  },
};

void main() {
  test('project scope lists spec, wiring and a11y findings', () {
    final all = healthFindingsFor(_health(), null);
    expect(all.map((f) => f['rule']), <String>[
      'schema',
      'undefined_tool_ref',
      'tool_refs_unverified',
      'icon.accessibleName',
    ]);
    expect(all.firstWhere((f) => f['rule'] == 'schema')['severity'], 'fail');
  });

  test('a page scope shows that page’s wiring and a11y findings', () {
    final home = healthFindingsFor(_health(), '/ui/pages/home');
    expect(home.map((f) => f['rule']), <String>[
      'undefined_tool_ref',
      'icon.accessibleName',
    ]);
  });

  test('a layer scope shows only its own findings', () {
    expect(
      healthFindingsFor(_health(), '/ui/theme').map((f) => f['rule']),
      <String>['schema'],
    );
    expect(healthFindingsFor(_health(), '/ui/navigation'), isEmpty);
  });

  test('no snapshot → nothing', () {
    expect(healthFindingsFor(null, null), isEmpty);
  });
}
