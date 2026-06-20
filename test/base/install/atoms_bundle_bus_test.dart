import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';

mb.McpBundle? _readSample() {
  // Use the on-disk wire_demo sample so the BundleAtom test runs
  // against a realistic manifest without re-implementing it inline.
  final path = p.normalize(
    p.join(Directory.current.path, 'example', 'wire_demo.mbd'),
  );
  return readBundleAt(path);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BundleAtom', () {
    test(
      'current() returns id / name / shortId / version / directory',
      () async {
        final bundle = _readSample()!;
        final atom = BundleAtom(bundle: bundle);
        final result = await atom.dispatch('current', const []);
        expect(result, isA<Map<String, dynamic>>());
        final m = result as Map<String, dynamic>;
        expect(m['id'], 'com.makemind.examples.wire_demo');
        expect(m['shortId'], 'wire_demo');
        expect(m['name'], 'Wire Demo');
        expect(m['version'], '0.1.0');
        expect(m['directory'], isNotEmpty);
      },
    );

    test('exposes via host bridge through host.bundle.current', () async {
      final bundle = _readSample()!;
      final rt = JsToolRuntime();
      await rt.attachHostBridge(
        atoms: [BundleAtom(bundle: bundle)],
        allowedAtoms: const ['bundle'],
      );

      final result = await rt.evaluateAsync(
        'host.bundle.current().then(function(v) { return v.shortId; })',
      );
      expect(result.stringResult, '"wire_demo"');
    });

    test('throws on unknown verb', () async {
      final bundle = _readSample()!;
      final atom = BundleAtom(bundle: bundle);
      expect(() => atom.dispatch('madeup', const []), throwsArgumentError);
    });
  });

  group('BusAtom', () {
    test('publish then consume drains the queue in FIFO order', () async {
      final atom = BusAtom();
      expect(await atom.dispatch('publish', ['changes', 'a']), 1);
      expect(await atom.dispatch('publish', ['changes', 'b']), 2);
      expect(await atom.dispatch('publish', ['changes', 'c']), 3);
      final drained = await atom.dispatch('consume', ['changes']);
      expect(drained, ['a', 'b', 'c']);
      // After drain, channel is empty — re-consume returns empty.
      final empty = await atom.dispatch('consume', ['changes']);
      expect(empty, isEmpty);
    });

    test('channels lists keys with pending payloads', () async {
      final atom = BusAtom();
      await atom.dispatch('publish', ['a', 1]);
      await atom.dispatch('publish', ['b', 2]);
      final channels = await atom.dispatch('channels', const []);
      expect((channels as List).toSet(), {'a', 'b'});
      // Consuming one drops it from the channel list.
      await atom.dispatch('consume', ['a']);
      final after = await atom.dispatch('channels', const []);
      expect(after, ['b']);
    });

    test('publish requires (channel, payload)', () async {
      final atom = BusAtom();
      expect(() => atom.dispatch('publish', ['a']), throwsArgumentError);
    });

    test('consume requires (channel)', () async {
      final atom = BusAtom();
      expect(() => atom.dispatch('consume', const []), throwsArgumentError);
    });

    test('end-to-end through host bridge — publish + consume', () async {
      final rt = JsToolRuntime();
      await rt.attachHostBridge(
        atoms: [BusAtom()],
        allowedAtoms: const ['bus'],
      );

      final result = await rt.evaluateAsync('''
        (async function() {
          await host.bus.publish('changes', { id: 1 });
          await host.bus.publish('changes', { id: 2 });
          const drained = await host.bus.consume('changes');
          return drained;
        })()
      ''');
      expect(jsonDecode(result.stringResult), [
        {'id': 1},
        {'id': 2},
      ]);
    });
  });
}
