/// The App Builder preview runs its project bundle's tools: a document's
/// `tool` action gets the bundle tool's response in the MCP wire shape the
/// runtime auto-merges (UI DSL 1.4 §4.4), on a preview-only server.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/install/preview_bundle_tools.dart';
import 'package:appplayer_studio/src/base/install/studio_kb.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _bundle(Directory root) {
  final dir = Directory(p.join(root.path, 'serving.mbd'))..createSync();
  File(p.join(dir.path, 'tools', 'desk.js'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(r'''
      async function sync() {
        var seen = (await host.kb.get('visits')) || 0;
        await host.kb.put('visits', seen + 1);
        return { roster: [{ name: 'Ava Bennett', statusLabel: 'Present' }], visits: seen + 1 };
      }
      function broken() { throw new Error('boom'); }
    ''');
  File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
    jsonEncode({
      'manifest': {'id': 'qa.preview.desk', 'name': 'Desk', 'version': '1'},
      'requires': {
        'builtinAtoms': ['kb'],
      },
      'tools': {
        'tools': [
          {
            'name': 'academy.sync',
            'kind': 'js',
            'target': {'entry': 'tools/desk.js', 'fn': 'sync'},
          },
          {
            'name': 'academy.broken',
            'kind': 'js',
            'target': {'entry': 'tools/desk.js', 'fn': 'broken'},
          },
          {
            'name': 'missing.entry',
            'kind': 'js',
            'target': {'fn': 'nothing'},
          },
        ],
      },
    }),
  );
  return dir.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late StudioKbWiring kb;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('preview_bundle_tools_');
    kb = StudioKbWiring(
      kv: mk.KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv')),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a dotted bundle tool answers the MCP wire shape with its JSON body, '
      'with host.kb wired', () async {
    final tools = await PreviewBundleTools.open(
      bundlePath: _bundle(tmp),
      kb: kb,
    );
    addTearDown(tools.dispose);

    final first = await tools.call('academy.sync', {}) as Map;
    expect(first['isError'], isFalse);
    final body = jsonDecode((first['content'] as List).single['text'] as String);
    expect(body['roster'], [
      {'name': 'Ava Bennett', 'statusLabel': 'Present'},
    ]);
    expect(body['visits'], 1);

    final second = await tools.call('academy.sync', {}) as Map;
    final again = jsonDecode((second['content'] as List).single['text'] as String);
    expect(again['visits'], 2, reason: 'host.kb state persists across calls');
  });

  test('a tool that throws answers isError, not an exception', () async {
    final tools = await PreviewBundleTools.open(
      bundlePath: _bundle(tmp),
      kb: kb,
    );
    addTearDown(tools.dispose);
    final r = await tools.call('academy.broken', {}) as Map;
    expect(r['isError'], isTrue);
    expect(jsonEncode(r['content']), contains('boom'));
  });

  test('an undeclared tool and a tool that did not register throw with why',
      () async {
    final tools = await PreviewBundleTools.open(
      bundlePath: _bundle(tmp),
      kb: kb,
    );
    addTearDown(tools.dispose);
    await expectLater(
      tools.call('nope', {}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('no tool named "nope"'),
        ),
      ),
    );
    expect(tools.failed.keys, contains('missing.entry'));
    await expectLater(
      tools.call('missing.entry', {}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('did not register'),
        ),
      ),
    );
  });

  test('a directory without a bundle and a closed runner throw', () async {
    final none = await PreviewBundleTools.open(
      bundlePath: p.join(tmp.path, 'nothing.mbd'),
    );
    await expectLater(none.call('academy.sync', {}), throwsStateError);

    final tools = await PreviewBundleTools.open(
      bundlePath: _bundle(tmp),
      kb: kb,
    );
    await tools.dispose();
    await expectLater(tools.call('academy.sync', {}), throwsStateError);
  });
}
