/// The argument guard checks a tool's `inputSchema` below the top level:
/// array `items` and nested object `properties` answer `invalidArguments`
/// with a field path, instead of letting the handler hit a cast error.
library;

import 'package:appplayer_studio/src/base/install/tool_call_guard.dart';
import 'package:flutter_test/flutter_test.dart';

// Shape of `form_builder.approval_request` / `form_builder.issue`.
const Map<String, dynamic> _schema = <String, dynamic>{
  'type': 'object',
  'properties': <String, dynamic>{
    'line': <String, dynamic>{
      'type': 'array',
      'items': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'approverId': <String, dynamic>{'type': 'string'},
          'roleLabel': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['approverId'],
      },
    },
    'formats': <String, dynamic>{
      'type': 'array',
      'items': <String, dynamic>{
        'type': 'string',
        'enum': <String>['pdf', 'image'],
      },
    },
    'options': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'dpi': <String, dynamic>{'type': 'integer'},
      },
      'required': <String>['dpi'],
    },
  },
};

void main() {
  test('well-formed nested arguments pass', () {
    expect(
      checkToolArgs(_schema, <String, dynamic>{
        'line': <Object>[
          <String, dynamic>{'approverId': 'bob', 'roleLabel': 'lead'},
        ],
        'formats': <Object>['pdf', 'image'],
        'options': <String, dynamic>{'dpi': 300},
      }),
      isEmpty,
    );
  });

  test('an array item of the wrong type is named by index', () {
    final problems = checkToolArgs(_schema, <String, dynamic>{
      'line': <Object>['bob'],
    });
    expect(problems, hasLength(1));
    expect(problems.single['field'], 'line[0]');
    expect(problems.single['problem'], 'type');
    expect(problems.single['expected'], 'object');
  });

  test('a missing field inside an array item is named by path', () {
    final problems = checkToolArgs(_schema, <String, dynamic>{
      'line': <Object>[
        <String, dynamic>{'approverId': 'bob'},
        <String, dynamic>{'roleLabel': 'owner'},
      ],
    });
    expect(problems.single['field'], 'line[1].approverId');
    expect(problems.single['problem'], 'missing');
  });

  test('a nested enum is advisory — values beyond it pass', () {
    // `formats: ['png']` was always accepted; the nested check covers shape
    // only so it does not start refusing calls that used to work.
    expect(
      checkToolArgs(_schema, <String, dynamic>{
        'formats': <Object>['pdf', 'png'],
      }),
      isEmpty,
    );
  });

  test('a top-level enum is enforced unless the caller opts out', () {
    const schema = <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mode': <String, dynamic>{
          'type': 'string',
          'enum': <String>['a', 'b'],
        },
      },
    };
    expect(
      checkToolArgs(schema, <String, dynamic>{'mode': 'c'}).single['problem'],
      'enum',
    );
    expect(
      checkToolArgs(schema, <String, dynamic>{
        'mode': 'c',
      }, enforceEnums: false),
      isEmpty,
    );
  });

  test('nested object properties are checked', () {
    final problems = checkToolArgs(_schema, <String, dynamic>{
      'options': <String, dynamic>{'dpi': 'high'},
    });
    expect(problems.single['field'], 'options.dpi');
    expect(problems.single['problem'], 'type');
    expect(
      checkToolArgs(_schema, <String, dynamic>{
        'options': <String, dynamic>{},
      }).single['field'],
      'options.dpi',
    );
  });
}
