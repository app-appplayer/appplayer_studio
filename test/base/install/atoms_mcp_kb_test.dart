import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:brain_kernel/mcp_host.dart' as mh;

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
    KbAtom buildAtom() => KbAtom(
      engine: _StubKnowledgeEngine(),
      storage: _StubDomainStorage(),
      namespace: 'com.test.kb',
    );

    test('throws on unknown verb', () async {
      // We can construct without a real engine for the unknown-verb
      // path because KbAtom doesn't touch the engine before verb
      // dispatch. Use a no-op stand-in.
      expect(
        () => buildAtom().dispatch('unknown', const []),
        throwsArgumentError,
      );
    });

    test('query requires text arg', () async {
      final atom = buildAtom();
      expect(() => atom.dispatch('query', const []), throwsArgumentError);
      expect(() => atom.dispatch('query', [42]), throwsArgumentError);
    });

    test('put / get / list / delete round-trip via storage', () async {
      final atom = buildAtom();
      // put — returns ok:true.
      expect(await atom.dispatch('put', ['greeting', 'hello']), {'ok': true});
      // get — returns the stored value.
      expect(await atom.dispatch('get', ['greeting']), 'hello');
      // list — returns [{key, value}] entries.
      final list = await atom.dispatch('list', const []) as List;
      expect(list.length, 1);
      expect((list.single as Map)['key'], 'greeting');
      // delete — removed:true on first call, false on second.
      expect(await atom.dispatch('delete', ['greeting']), {'removed': true});
      expect(await atom.dispatch('delete', ['greeting']), {'removed': false});
      expect(await atom.dispatch('get', ['greeting']), isNull);
    });

    test('list with prefix filters keys', () async {
      final atom = buildAtom();
      await atom.dispatch('put', ['recent/a', 1]);
      await atom.dispatch('put', ['recent/b', 2]);
      await atom.dispatch('put', ['pin/c', 3]);
      final recents = await atom.dispatch('list', const ['recent/']) as List;
      expect(recents.length, 2);
      expect((recents.map((e) => (e as Map)['key']).toSet()), {
        'recent/a',
        'recent/b',
      });
    });

    test('put requires non-empty string key', () async {
      final atom = buildAtom();
      expect(() => atom.dispatch('put', ['', 'v']), throwsArgumentError);
      expect(() => atom.dispatch('put', [42, 'v']), throwsArgumentError);
    });

    test(
      'namespace pin is honoured — never leaks to storage callers',
      () async {
        final storage = _StubDomainStorage();
        final a = KbAtom(
          engine: _StubKnowledgeEngine(),
          storage: storage,
          namespace: 'com.a',
        );
        final b = KbAtom(
          engine: _StubKnowledgeEngine(),
          storage: storage,
          namespace: 'com.b',
        );
        await a.dispatch('put', ['k', 'A']);
        await b.dispatch('put', ['k', 'B']);
        expect(await a.dispatch('get', ['k']), 'A');
        expect(await b.dispatch('get', ['k']), 'B');
      },
    );
  });
}

/// Minimal stand-in — only the surface KbAtom touches in error paths.
/// We avoid testing the happy query path here since it depends on the
/// engine's internal index which is exercised by mcp_bundle's own
/// tests; the goal here is only to verify the atom-level argument
/// guards.
class _StubKnowledgeEngine implements mk.KnowledgeQueryEngine {
  @override
  noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'stub: ${invocation.memberName} not expected during error-path tests',
    );
  }
}

/// In-memory DomainStorage stand-in for atom-level tests — exercises
/// the same namespace-scoping contract as JsonFileDomainStorage but
/// without touching disk.
class _StubDomainStorage implements mk.DomainStorage {
  final Map<String, Map<String, mk.DomainValue>> _data =
      <String, Map<String, mk.DomainValue>>{};

  Map<String, mk.DomainValue> _ns(String namespace) =>
      _data.putIfAbsent(namespace, () => <String, mk.DomainValue>{});

  @override
  Future<void> put(String namespace, String key, mk.DomainValue value) async {
    _ns(namespace)[key] = value;
  }

  @override
  Future<mk.DomainValue> get(String namespace, String key) async {
    return _ns(namespace)[key];
  }

  @override
  Future<List<mk.DomainEntry>> list(
    String namespace, {
    String prefix = '',
  }) async {
    final ns = _ns(namespace);
    return <mk.DomainEntry>[
      for (final e in ns.entries)
        if (prefix.isEmpty || e.key.startsWith(prefix))
          mk.DomainEntry(key: e.key, value: e.value),
    ];
  }

  @override
  Future<bool> delete(String namespace, String key) async {
    final ns = _ns(namespace);
    if (!ns.containsKey(key)) return false;
    ns.remove(key);
    return true;
  }

  @override
  Future<void> clearNamespace(String namespace) async {
    _data.remove(namespace);
  }
}
