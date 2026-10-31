/// `celm.*` capability: a declared goal runs through host tools that stand in
/// for the sensor and the hands. Driven by tool name with JSON arguments, the
/// way a bundle, the workbench LLM or a remote caller would.
library;

import 'dart:convert';

import 'package:appplayer_studio/src/base/install/celm_capability.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> cell(Object? v, [double q = 0.95]) => {
  'value': v,
  'quality': q,
};

const surfacePack = {
  'pack': 'celm/surface@0.1',
  'id': 'desktop-hid',
  'skills': [
    {
      'name': 'open_file',
      'params': {'path': 'string'},
      'preconditions': [
        {'kind': 'observe', 'expr': 'app.focused == true'},
      ],
      'action': {
        'sequence': [
          {
            'port': 'hid.key',
            'args': {'combo': 'Cmd+O'},
          },
          {
            'port': 'hid.type',
            'args': {'text': r'$path'},
          },
          {
            'port': 'hid.key',
            'args': {'combo': 'Enter'},
          },
        ],
      },
      'postconditions': [
        {
          'kind': 'observe',
          'expr': r'window.frontmost.title contains basename($path)',
          'requires_quality': 0.8,
        },
        {
          'kind': 'judge',
          'ask': 'Did the document open in a usable state?',
          'reads': ['window.frontmost'],
        },
      ],
      'writes': true,
    },
  ],
  'goals': [
    {
      'id': 'open_document',
      'params': {'path': 'string'},
      'observe': {'scope': 'screen', 'depth': 'structure'},
      'entry': 'open',
      'steps': {
        'open': {
          'skill': 'open_file',
          'params': {'path': r'$path'},
          'on_pass': null,
        },
      },
      'completion': [
        {
          'kind': 'observe',
          'expr': r'window.frontmost.title contains basename($path)',
        },
      ],
    },
  ],
};

const domainPack = {
  'pack': 'celm/domain@0.1',
  'id': 'editor',
  'references': <Object>[],
  'reasoner': {
    'kind': 'rules',
    'rules': [
      {
        'question': 'usable',
        'when': 'window.frontmost.usable == true',
        'verdict': true,
        'confidence': 0.95,
        'rationale': 'the window reports itself usable',
      },
      {
        'question': 'usable',
        'when': 'window.frontmost.usable == false',
        'verdict': false,
        'confidence': 0.95,
      },
    ],
  },
};

const manifest = {
  'manifest': 'celm/manifest@0.1',
  'instance': 'example',
  'inputs': [
    {
      'channel': 'vision',
      'port': 'mcp:vision.read',
      'schema': 'descriptor@0.3',
    },
  ],
  'outputs': [
    {
      'actuator': 'hid',
      'port': 'mcp:hid',
      'vocab': ['click', 'type', 'key'],
      'writes': 'allow_list',
      'allowed': ['click', 'type', 'key'],
    },
  ],
  'surface_pack': 'desktop-hid',
  'domain_pack': 'editor',
  'reasoner': {'kind': 'rules'},
  'regime': 'discrete-verify-retry',
};

Map<String, dynamic> _json(mk.KernelToolResult r) =>
    jsonDecode(r.content.whereType<mk.KernelTextContent>().first.text)
        as Map<String, dynamic>;

void main() {
  late mk.InProcessKernelServerHost host;
  late List<String> hands;

  void tool(String name, Future<Object?> Function(Map<String, dynamic>) f) {
    host.addTool(
      name: name,
      description: name,
      inputSchema: const {'type': 'object'},
      handler:
          (a) async => mk.KernelToolResult(
            content: [mk.KernelTextContent(text: jsonEncode(await f(a)))],
          ),
    );
  }

  setUp(() {
    host = mk.InProcessKernelServerHost();
    hands = [];
    final registry = mk.HostToolRegistry(
      endpoint: host,
      attachToDispatcher: (_, _) {},
      detachFromDispatcher: (_) {},
    );
    // The hands: each verb is a host tool.
    for (final verb in ['click', 'type', 'key']) {
      tool('hid.$verb', (a) async {
        hands.add('hid.$verb');
        return {'ok': true};
      });
    }
    // The eyes: honest about scope and depth; the document is open once the
    // three declared actions have happened.
    tool('vision.read', (a) async {
      final opened = hands.length >= 3;
      return {
        'descriptor': {
          'app': {'focused': cell(true), 'name': cell('Editor')},
          'window': {
            'frontmost': {
              'title': cell(opened ? 'notes.txt' : 'Untitled'),
              'usable': cell(opened),
            },
          },
        },
        'coverage': [
          {'scope': a['scope'] ?? 'screen', 'depth': a['depth'] ?? 'coarse'},
        ],
        'at': DateTime.now().toIso8601String(),
      };
    });
    registerCelmCapability(registry, host: host);
  });

  Map<String, dynamic> loadArgs() => {
    'manifest': manifest,
    'surfacePacks': {'desktop-hid': surfacePack},
    'domainPacks': {'editor': domainPack},
    'perception': {'server': 'vision', 'tool': 'read'},
    'actuators': {
      'hid': {
        'server': 'hid',
        'vocabulary': ['click', 'type', 'key'],
        'kinds': {'click': 'discrete', 'type': 'discrete', 'key': 'discrete'},
      },
    },
  };

  Future<Map<String, dynamic>> run(
    String name, [
    Map<String, dynamic>? a,
  ]) async => _json(await host.callTool(name, a ?? {}));

  test('surface: load plus the seven port methods', () {
    expect(
      host.toolDefinitions.map((t) => t.name),
      containsAll(<String>[
        'celm.load',
        'celm.execute',
        'celm.cancel',
        'celm.observe',
        'celm.progress',
        'celm.explain',
        'celm.resume',
        'celm.standalone',
      ]),
    );
  });

  test(
    'before a load the loop answers not_loaded, not an empty success',
    () async {
      final r = await host.callTool('celm.execute', {
        'goal': {
          'id': 'open_document',
          'params': {'path': '/tmp/notes.txt'},
        },
      });
      expect(r.isError, isTrue);
      expect(_json(r)['code'], 'celm.not_loaded');
    },
  );

  test(
    'a declared goal runs over host tools and the hands do what was declared',
    () async {
      expect((await run('celm.load', loadArgs()))['ok'], isTrue);

      final started = await run('celm.execute', {
        'goal': {
          'id': 'open_document',
          'params': {'path': '/tmp/notes.txt'},
        },
      });
      final runId = started['runId'] as String;

      Map<String, dynamic> progress = {};
      for (var i = 0; i < 100; i++) {
        progress = await run('celm.progress', {'runId': runId});
        if (progress['outcome'] != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(progress['outcome'], isNotNull, reason: jsonEncode(progress));
      expect(
        jsonEncode(progress['outcome']).toLowerCase(),
        contains('completed'),
      );
      expect(hands, ['hid.key', 'hid.type', 'hid.key']);

      final standalone = await run('celm.standalone', {'runId': runId});
      expect(jsonEncode(standalone), contains('statement'));
    },
  );

  // `pack` / `packVersion` arrive with mcp_celm 0.1.1; remove the skip once
  // that version is the one this package resolves.
  test(
    'judged conclusions carry the domain pack and its version',
    skip: 'needs mcp_celm 0.1.1 (unpublished)',
    () async {
      final args = jsonDecode(jsonEncode(loadArgs())) as Map<String, dynamic>;
      (args['domainPacks'] as Map)['editor'] = {
        ...domainPack,
        'version': '0.2.0',
      };
      // A judgment in the postconditions: the rules reasoner answers it.
      final skill =
          ((args['surfacePacks'] as Map)['desktop-hid'] as Map)['skills'][0]
              as Map;
      (skill['postconditions'] as List).add({
        'kind': 'judge',
        'ask': 'Did the document open in a usable state?',
        'reads': ['window.frontmost'],
        'requires_depth': 'structure',
      });
      expect((await run('celm.load', args))['ok'], isTrue);
      final started = await run('celm.execute', {
        'goal': {
          'id': 'open_document',
          'params': {'path': '/tmp/notes.txt'},
        },
      });
      final runId = started['runId'] as String;
      Map<String, dynamic> progress = {};
      for (var i = 0; i < 100; i++) {
        progress = await run('celm.progress', {'runId': runId});
        if (progress['outcome'] != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final outcome = jsonEncode(progress['outcome']);
      expect(outcome, contains('"pack":"editor"'), reason: outcome);
      expect(outcome, contains('"packVersion":"0.2.0"'), reason: outcome);
    },
  );

  test(
    'observe goes through the perception tool and states its coverage',
    () async {
      await run('celm.load', loadArgs());
      final o = await run('celm.observe', {
        'request': {'scope': 'screen', 'depth': 'structure'},
      });
      expect(o['coverage'], [
        {'scope': 'screen', 'depth': 'structure'},
      ]);
    },
  );

  test('a tool the host does not serve fails at load, with the name', () async {
    final bad =
        loadArgs()..['perception'] = {'server': 'vision', 'tool': 'nope'};
    final r = await host.callTool('celm.load', bad);
    expect(r.isError, isTrue);
    expect(_json(r)['code'], 'celm.unknown_tool');
    expect(_json(r)['error'], contains('vision.nope'));
  });

  test('an actuator verb the host does not serve fails at load', () async {
    final args = loadArgs();
    (args['actuators'] as Map)['hid'] = {
      'server': 'hid',
      'vocabulary': ['click', 'teleport'],
    };
    final r = await host.callTool('celm.load', args);
    expect(_json(r)['code'], 'celm.unknown_tool');
  });

  test('a load the package rejects keeps its stable code and leaves the '
      'previous loop untouched', () async {
    await run('celm.load', loadArgs());
    final args =
        loadArgs()..['manifest'] = {...manifest, 'surface_pack': 'nonexistent'};
    final r = await host.callTool('celm.load', args);
    expect(r.isError, isTrue);
    expect(_json(r)['code'], isNot('celm.not_loaded'));
    final after = await host.callTool('celm.observe', {});
    expect(
      after.isError,
      isNot(true),
      reason: 'the loop loaded before must still answer',
    );
  });
}
