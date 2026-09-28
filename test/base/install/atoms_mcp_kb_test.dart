import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;

mk.KernelToolResult _ok([Object? body]) {
  return mk.KernelToolResult(
    content: <mk.KernelContent>[
      mk.KernelTextContent(text: jsonEncode(body ?? <String, dynamic>{})),
    ],
    isError: false,
  );
}

mk.KernelToolResult _prose(String text) {
  return mk.KernelToolResult(
    content: <mk.KernelContent>[mk.KernelTextContent(text: text)],
    isError: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('McpAtom', () {
    test('callTool dispatches to a registered host tool', () async {
      final boot = mk.InProcessKernelServerHost();
      boot.addTool(
        name: 'studio.echo',
        description: 'echo',
        inputSchema: const {'type': 'object', 'properties': {}},
        handler: (args) async => _ok({'text': args['text']}),
      );
      final atom = McpAtom(boot: boot);
      final result =
          await atom.dispatch('callTool', [
                'studio.echo',
                {'text': 'hi'},
              ])
              as Map<String, dynamic>;
      expect(result['isError'], isFalse);
      expect(result['body'], {'text': 'hi'});
    });

    test('callTool surfaces isError flag', () async {
      final boot = mk.InProcessKernelServerHost();
      boot.addTool(
        name: 'studio.fail',
        description: 'fail',
        inputSchema: const {'type': 'object', 'properties': {}},
        handler:
            (args) async => mk.KernelToolResult(
              content: <mk.KernelContent>[mk.KernelTextContent(text: 'nope')],
              isError: true,
            ),
      );
      final atom = McpAtom(boot: boot);
      final result =
          await atom.dispatch('callTool', ['studio.fail', const {}])
              as Map<String, dynamic>;
      expect(result['isError'], isTrue);
      // Plain text doesn't decode as JSON — falls through to raw text.
      expect(result['body'], 'nope');
    });

    test('callTool keeps prose responses as String', () async {
      final boot = mk.InProcessKernelServerHost();
      boot.addTool(
        name: 'studio.prose',
        description: 'prose',
        inputSchema: const {'type': 'object', 'properties': {}},
        handler: (args) async => _prose('plain text reply'),
      );
      final atom = McpAtom(boot: boot);
      final result =
          await atom.dispatch('callTool', ['studio.prose', const {}])
              as Map<String, dynamic>;
      expect(result['body'], 'plain text reply');
    });

    test('listTools returns registered host tool ids', () async {
      final boot = mk.InProcessKernelServerHost();
      boot.addTool(
        name: 'studio.a',
        description: '',
        inputSchema: const {'type': 'object', 'properties': {}},
        handler: (args) async => _ok(),
      );
      boot.addTool(
        name: 'studio.b',
        description: '',
        inputSchema: const {'type': 'object', 'properties': {}},
        handler: (args) async => _ok(),
      );
      final atom = McpAtom(boot: boot);
      final list = await atom.dispatch('listTools', const []);
      expect((list as List).toSet(), {'studio.a', 'studio.b'});
    });

    test('callTool requires a non-empty toolName', () async {
      final boot = mk.InProcessKernelServerHost();
      final atom = McpAtom(boot: boot);
      expect(() => atom.dispatch('callTool', ['']), throwsArgumentError);
    });

    test('end-to-end through host bridge', () async {
      final boot = mk.InProcessKernelServerHost();
      boot.addTool(
        name: 'studio.echo',
        description: 'echo',
        inputSchema: const {'type': 'object', 'properties': {}},
        handler: (args) async => _ok({'text': args['text']}),
      );
      final rt = JsToolRuntime();
      await rt.attachHostBridge(
        atoms: [McpAtom(boot: boot)],
        allowedAtoms: const ['mcp'],
      );

      final result = await rt.evaluateAsync('''
        host.mcp.callTool('studio.echo', { text: 'hello' })
          .then(function(r) { return r.body.text; })
      ''');
      expect(result.stringResult, '"hello"');
    });
  });

  group('KbAtom', () {
    late Directory tmp;
    late mk.KvStoragePortAdapter kv;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('vibe_kb_atom_');
      kv = mk.KvStoragePortAdapter(rootDir: tmp.path);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    KbAtom atomFor(String appId, {mk.KbRecordStore? records}) => KbAtom(
      mk.BundleKbStore(appId: appId, records: records ?? mk.KvKbRecordStore(kv)),
    );

    test('put / get / list / delete answer the kernel contract', () async {
      final atom = atomFor('bundle:com.test.kb');
      expect(await atom.dispatch('put', [
        'a',
        {'n': 1},
      ]), {'ok': true});
      expect(await atom.dispatch('get', ['a']), {'n': 1});
      expect(await atom.dispatch('list', ['']), [
        {
          'key': 'a',
          'value': {'n': 1},
        },
      ]);
      expect(await atom.dispatch('delete', ['a']), {'removed': true});
      expect(await atom.dispatch('get', ['a']), isNull);
    });

    test('records live in the kernel kv under app/<appId>/kb/', () async {
      final atom = atomFor('bundle:com.test.kb');
      await atom.dispatch('put', ['recent/x', 'v']);
      final keys = await kv.keys(prefix: 'app/');
      expect(keys, isNotEmpty);
      expect(
        keys.every((k) => k.startsWith('app/bundle%3Acom.test.kb/kb/')),
        isTrue,
        reason: 'got $keys',
      );
    });

    test('list with prefix filters keys', () async {
      final atom = atomFor('bundle:com.test.kb');
      await atom.dispatch('put', ['recent/a', 1]);
      await atom.dispatch('put', ['recent/b', 2]);
      await atom.dispatch('put', ['pin/c', 3]);
      final recents = await atom.dispatch('list', const ['recent/']) as List;
      expect(recents.map((e) => (e as Map)['key']).toList(), [
        'recent/a',
        'recent/b',
      ]);
    });

    test('an invalid key is KB_INVALID_KEY', () async {
      final atom = atomFor('bundle:com.test.kb');
      for (final key in <Object?>['../x', '', '/abs', 'a//b', 42]) {
        await expectLater(
          atom.dispatch('put', [key, 1]),
          throwsA(
            isA<mk.KbError>().having(
              (e) => e.code,
              'code',
              mk.KbError.invalidKey,
            ),
          ),
          reason: 'key $key',
        );
      }
    });

    test('a value JSON cannot carry is KB_INVALID_VALUE', () async {
      final atom = atomFor('bundle:com.test.kb');
      await expectLater(
        atom.dispatch('put', ['a', Object()]),
        throwsA(
          isA<mk.KbError>().having(
            (e) => e.code,
            'code',
            mk.KbError.invalidValue,
          ),
        ),
      );
    });

    test('app identities never see each other', () async {
      final records = mk.KvKbRecordStore(kv);
      final a = atomFor('bundle:com.a', records: records);
      final b = atomFor('listing:L1', records: records);
      await a.dispatch('put', ['k', 'A']);
      await b.dispatch('put', ['k', 'B']);
      expect(await a.dispatch('get', ['k']), 'A');
      expect(await b.dispatch('get', ['k']), 'B');
    });

    test('a write on a stale version is a conflict, force overwrites', () async {
      final records = mk.KvKbRecordStore(kv);
      final first = atomFor('bundle:com.test.kb', records: records);
      final second = atomFor('bundle:com.test.kb', records: records);
      await first.dispatch('put', ['k', 1]);
      expect(await second.dispatch('get', ['k']), 1);
      await second.dispatch('put', ['k', 2]);
      final stale = await first.dispatch('put', ['k', 3]) as Map;
      expect(stale['ok'], isFalse);
      expect((stale['conflict'] as Map)['value'], 2);
      expect(await first.dispatch('put', [
        'k',
        3,
        {'force': true},
      ]), {'ok': true});
    });

    test('throws on unknown verb', () async {
      expect(
        () => atomFor('bundle:x').dispatch('unknown', const []),
        throwsArgumentError,
      );
    });
  });
}
