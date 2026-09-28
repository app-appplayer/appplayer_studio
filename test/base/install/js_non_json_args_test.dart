/// Arguments JSON cannot carry are refused at the bridge, not stored as null
/// (bundle spec 04_Tools §4.8). Same cases as AppPlayer's core bridge, on the
/// studio's real worker isolate.
library;

import 'dart:convert';

import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart'
    show BundleKbStore, InMemoryKvStoragePort, KbError, KvKbRecordStore;
import 'package:flutter_test/flutter_test.dart';

class _RecordingAtom extends AtomCategory {
  final List<List<Object?>> calls = [];

  @override
  String get key => 'probe';

  @override
  List<AtomVerb> get verbs => const [AtomVerb('echo')];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    calls.add(args);
    return args;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late JsToolRuntime rt;
  late BundleKbStore store;
  late _RecordingAtom probe;

  setUp(() async {
    rt = JsToolRuntime();
    store = BundleKbStore(
      appId: 'bundle:works.notes',
      records: KvKbRecordStore(InMemoryKvStoragePort()),
    );
    probe = _RecordingAtom();
    await rt.attachHostBridge(
      atoms: [KbAtom(store), probe],
      allowedAtoms: const {'kb', 'probe'},
    );
  });

  tearDown(() => rt.dispose());

  Future<String> outcome(String call) async {
    final r = await rt.evaluateAsync(
      '$call.then(function (v) { return "ok:" + JSON.stringify(v); }, '
      'function (e) { return "err:" + e.message; })',
    );
    expect(r.isError, isFalse, reason: r.stringResult);
    return jsonDecode(r.stringResult) as String;
  }

  test('kb values: function, NaN, Infinity, nested function, cycle', () async {
    for (final value in [
      'function () {}',
      'NaN',
      'Infinity',
      '{x: Infinity}',
      '{a: 1, b: function () {}}',
      '[1, -Infinity]',
      '(function () { var o = {}; o.self = o; return o; })()',
    ]) {
      final got = await outcome('host.kb.put("doc", $value)');
      expect(got, startsWith('err:'), reason: value);
      expect(got, contains(KbError.invalidValue), reason: value);
    }
    expect(await store.get('doc'), isNull, reason: 'nothing was stored');
  });

  test('a kb key JSON cannot carry is an invalid key', () async {
    final got = await outcome('host.kb.get(function () {})');
    expect(got, contains(KbError.invalidKey));
  });

  test('undefined crosses as null, an undefined property is omitted, '
      'toJSON is followed', () async {
    expect(
      await outcome('host.kb.put("u", {skip: undefined, keep: 1})'),
      'ok:{"ok":true}',
    );
    expect(await store.get('u'), {'keep': 1});
    expect(await outcome('host.kb.put("b", undefined)'), 'ok:{"ok":true}');
    expect(await store.get('b'), isNull);
    expect(
      await outcome('host.kb.put("c", {when: new Date(0)})'),
      'ok:{"ok":true}',
    );
    expect(await store.get('c'), {'when': '1970-01-01T00:00:00.000Z'});
  });

  test('an atom without its own policy is refused by name and never '
      'dispatched', () async {
    final got = await outcome('host.probe.echo(function () {})');
    expect(
      got,
      'err:Invalid argument(s): probe.echo: argument 0 is function, which '
      'JSON cannot carry',
    );
    final nested = await outcome('host.probe.echo("a", {cb: function () {}})');
    expect(nested, contains('argument 1.cb is function'));
    expect(probe.calls, isEmpty);

    expect(
      await outcome('host.probe.echo("a", [1, undefined])'),
      'ok:["a",[1,null]]',
    );
    expect(probe.calls.single, [
      'a',
      [1, null],
    ]);
  });
}
