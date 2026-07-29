/// Composition Profile seam — the studio half of `composition_host`.
///
/// These lock the rules that produced real symptoms on the bench, so a later
/// change cannot quietly undo one:
///
///   c1  unwired seam → NO hooks, so `view` fails closed to its own fallback
///       instead of resolving a foreign `$ref` against this surface's server.
///   c2  wired seam → all four hooks present. A resolver on its own renders an
///       embedded subtree whose controls take the app's own path and land on a
///       session with no client for that device.
///   c3  a tool call goes to the ORIGIN's connection id, not the host's.
///   c4  an origin is opened on FIRST USE, and only once — boards serve a
///       single peer at a time, so holding one connection per registered device
///       has the last one reset the others.
///   c5  an already-live origin is NOT re-opened (the re-probe that reset the
///       composition connection).
///   c6  a watch READS ONCE before subscribing — a subscription reports only
///       changes, so a view that waits for one shows nothing until the value
///       happens to move, which is indistinguishable from a broken binding.
///   c7  the disposer unsubscribes.
///   c8  an origin that cannot be opened surfaces as an error, never as this
///       surface's own definition under another server's identity.
///   c9  the kernel's JSON-text envelope is decoded back to an object, and
///       non-JSON text survives as text.
library;

import 'dart:async';

import 'package:appplayer_studio/src/base/install/composition_host/composition_host.dart';
import 'package:appplayer_studio/src/base/servers/composition_seam.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    show MCPUIRuntime;
import 'package:appplayer_studio/runtime.dart' as studio show MCPUIRuntime;
import 'package:flutter_test/flutter_test.dart';

class _FakeConn implements mk.KernelClientConnection {
  _FakeConn(this.id, {this.live = true});

  @override
  final String id;

  /// A host may still LIST a connection whose link is gone. Liveness, not mere
  /// presence, is what decides whether an origin must be re-opened.
  bool live;

  @override
  bool get isConnected => live;

  final _updates = StreamController<String>.broadcast();

  /// Simulates the server reporting a resource changed.
  void pushUpdate(String uri) => _updates.add(uri);

  @override
  Stream<String> get resourceUpdates => _updates.stream;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('${i.memberName}');
}

class _FakeHost implements mk.KernelClientHost {
  _FakeHost(this._conns);
  final List<mk.KernelClientConnection> _conns;

  @override
  List<mk.KernelClientConnection> get connections => _conns;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('${i.memberName}');
}

/// Records every kernel `mcp.*` call the hooks make.
class _Calls {
  final List<(String, Map<String, dynamic>)> log = <(String, Map<String, dynamic>)>[];
  Object? Function(String tool, Map<String, dynamic> args)? reply;

  Future<Object?> call(String tool, Map<String, dynamic> args) async {
    log.add((tool, args));
    return reply?.call(tool, args);
  }

  List<String> get tools => log.map((e) => e.$1).toList();
}

void main() {
  setUp(StudioCompositionSeam.resetForTest);
  tearDown(StudioCompositionSeam.resetForTest);

  test('c1 an unwired seam yields no hooks (view fails closed)', () {
    expect(StudioCompositionSeam.isWired, isFalse);
    expect(
      StudioCompositionSeam.hooksFor(clientHost: () => null),
      isNull,
      reason: 'without hooks the runtime keeps no resolver, so `view` renders '
          'its own fallback instead of resolving a foreign ref locally',
    );
  });

  test('c2 applyCompositionHooks registers ALL FOUR on the runtime', () async {
    final calls = _Calls();
    StudioCompositionSeam.register(call: calls.call, clientHost: () => null);
    final hooks = StudioCompositionSeam.hooksFor(clientHost: () => null);
    expect(hooks, isNotNull);

    // A real runtime, not a structural check: `CompositionHooks` cannot be
    // built with fewer than four, so asserting on the object proves nothing.
    // What can regress is the REGISTRATION — dropping one line here is exactly
    // how a screen ends up rendering and doing nothing.
    final runtime = MCPUIRuntime(enableDebugMode: false);
    await runtime.initialize(<String, dynamic>{
      'type': 'page',
      'content': <String, dynamic>{'type': 'text', 'value': ''},
    });
    final renderer = runtime.engine!.renderer;
    expect(renderer.definitionResolver, isNull, reason: 'precondition');

    applyCompositionHooks(runtime, hooks);

    expect(renderer.definitionResolver, isNotNull, reason: 'view resolution');
    expect(renderer.originToolCaller, isNotNull, reason: 'controls act');
    expect(renderer.originResourceWatcher, isNotNull, reason: 'live values');
    expect(renderer.originResourceReader, isNotNull, reason: 'one-shot reads');
  });

  test('c2b an unwired seam registers nothing (view stays fail-closed)',
      () async {
    final runtime = MCPUIRuntime(enableDebugMode: false);
    await runtime.initialize(<String, dynamic>{
      'type': 'page',
      'content': <String, dynamic>{'type': 'text', 'value': ''},
    });

    applyCompositionHooks(
        runtime, StudioCompositionSeam.hooksFor(clientHost: () => null));

    expect(runtime.engine!.renderer.definitionResolver, isNull);
    expect(runtime.engine!.renderer.originToolCaller, isNull);
  });

  test('c3 a tool call is routed to the ORIGIN connection', () async {
    final calls = _Calls();
    StudioCompositionSeam.register(call: calls.call, clientHost: () => null);
    final hooks = StudioCompositionSeam.hooksFor(
      clientHost: () => _FakeHost(<mk.KernelClientConnection>[_FakeConn('board-a')]),
    )!;

    await hooks.callTool(
      <String, dynamic>{'connection': 'board-a'},
      'relay.set',
      <String, dynamic>{'on': true},
    );

    expect(calls.tools, contains('mcp.call_tool'));
    final args = calls.log.firstWhere((e) => e.$1 == 'mcp.call_tool').$2;
    expect(args['id'], 'board-a',
        reason: 'the control belongs to the embedded origin, not the host');
    expect(args['tool'], 'relay.set');
    expect(args['args'], <String, dynamic>{'on': true});
  });

  test('c4 an unheld origin is opened on first use', () async {
    final calls = _Calls();
    final opened = <String>[];
    StudioCompositionSeam.register(
      call: calls.call,
      clientHost: () => null,
      openOrigin: (id) async => opened.add(id),
    );
    final hooks = StudioCompositionSeam.hooksFor(
      clientHost: () => _FakeHost(const <mk.KernelClientConnection>[]),
    )!;

    await hooks.readResource(
        <String, dynamic>{'connection': 'board-b'}, 'sensor://t');

    expect(opened, <String>['board-b'],
        reason: 'a document names an origin; the host opens it on first use');
  });

  test('c5 an already-live origin is not re-opened', () async {
    final calls = _Calls();
    final opened = <String>[];
    StudioCompositionSeam.register(
      call: calls.call,
      clientHost: () => null,
      openOrigin: (id) async => opened.add(id),
    );
    final hooks = StudioCompositionSeam.hooksFor(
      clientHost: () => _FakeHost(<mk.KernelClientConnection>[_FakeConn('board-c')]),
    )!;

    await hooks.readResource(
        <String, dynamic>{'connection': 'board-c'}, 'sensor://t');

    expect(opened, isEmpty,
        reason: 're-probing a confirmed node opens a second connection, which '
            'resets the one composition is using');
  });

  test('c6/c7 a watch reads once, subscribes, and its disposer unsubscribes',
      () async {
    final calls = _Calls()
      ..reply = (tool, args) => tool == 'mcp.read_resource' ? 21.5 : null;
    StudioCompositionSeam.register(call: calls.call, clientHost: () => null);
    final hooks = StudioCompositionSeam.hooksFor(
      clientHost: () => _FakeHost(<mk.KernelClientConnection>[_FakeConn('board-d')]),
    )!;

    final seen = <dynamic>[];
    final dispose = await hooks.watchResource(
      <String, dynamic>{'connection': 'board-d'},
      'sensor://t',
      seen.add,
    );

    expect(seen, <dynamic>[21.5],
        reason: 'a subscription reports only CHANGES — without a first read a '
            'slow value renders its label and nothing else');
    expect(calls.tools, contains('mcp.subscribe_resource'));

    dispose();
    await Future<void>.delayed(Duration.zero);
    expect(calls.tools, contains('mcp.unsubscribe_resource'));
  });

  test('c8 an origin that cannot be opened throws (never a local substitute)',
      () async {
    final calls = _Calls();
    StudioCompositionSeam.register(
        call: calls.call, clientHost: () => null); // no opener wired
    final hooks = StudioCompositionSeam.hooksFor(
      clientHost: () => _FakeHost(const <mk.KernelClientConnection>[]),
    )!;

    await expectLater(
      hooks.watchResource(
          <String, dynamic>{'connection': 'ghost'}, 'sensor://t', (_) {}),
      throwsA(isA<StateError>()),
      reason: 'a silent substitution renders one device UI under another '
          "device's identity",
    );
  });

  test('c9 the kernel JSON-text envelope is decoded; non-JSON stays text',
      () async {
    final decoded = await kernelToolCallFrom((tool, args) async =>
        mk.KernelToolResult(content: <mk.KernelContent>[
          mk.KernelTextContent(text: '{"value":7}'),
        ]))('mcp.read_resource', const <String, dynamic>{});
    expect(decoded, <String, dynamic>{'value': 7});

    final plain = await kernelToolCallFrom((tool, args) async =>
        mk.KernelToolResult(content: <mk.KernelContent>[
          mk.KernelTextContent(text: 'not json'),
        ]))('mcp.read_resource', const <String, dynamic>{});
    expect(plain, 'not json',
        reason: 'a device serving a plain string is answering, not failing');

    final empty = await kernelToolCallFrom((tool, args) async =>
        mk.KernelToolResult(content: const <mk.KernelContent>[]))(
        'mcp.read_resource', const <String, dynamic>{});
    expect(empty, isNull);
  });

  test('c10 a listed-but-DEAD connection is re-opened, not given up on',
      () async {
    final calls = _Calls();
    final dead = _FakeConn('board-e', live: false);
    final opened = <String>[];
    StudioCompositionSeam.register(
      call: calls.call,
      clientHost: () => null,
      openOrigin: (id) async {
        opened.add(id);
        dead.live = true; // the host re-dialled and the link came back
      },
    );
    final hooks = StudioCompositionSeam.hooksFor(
      clientHost: () => _FakeHost(<mk.KernelClientConnection>[dead]),
    )!;

    await hooks.readResource(
        <String, dynamic>{'connection': 'board-e'}, 'sensor://t');

    expect(opened, <String>['board-e'],
        reason: 'treating "the id is registered" as "the origin is open" makes '
            'a composed tile give up permanently while the standalone path '
            'recovers on the next tap');
  });

  test('c11 a resolved definition is cached per (origin, ref)', () async {
    final calls = _Calls()
      ..reply = (tool, args) => <String, dynamic>{
            'type': 'page',
            'content': <String, dynamic>{'type': 'text', 'value': 'x'},
          };
    StudioCompositionSeam.register(call: calls.call, clientHost: () => null);
    final hooks = StudioCompositionSeam.hooksFor(
      clientHost: () =>
          _FakeHost(<mk.KernelClientConnection>[_FakeConn('board-f')]),
    )!;
    const origin = <String, dynamic>{'connection': 'board-f'};

    await hooks.resolveDefinition('ui://app', origin);
    final afterFirst =
        calls.tools.where((t) => t == 'mcp.read_resource').length;
    await hooks.resolveDefinition('ui://app', origin);
    final afterSecond =
        calls.tools.where((t) => t == 'mcp.read_resource').length;

    expect(afterFirst, 1);
    expect(afterSecond, 1,
        reason: 're-reading on every mount makes re-entry spin a spinner on a '
            'live connection, so a composed tile looks like it is reconnecting '
            'while the standalone screen returns instantly');
  });

  test('c12 (re)opening an origin drops its cached definitions', () async {
    final calls = _Calls()
      ..reply = (tool, args) => <String, dynamic>{
            'type': 'page',
            'content': <String, dynamic>{'type': 'text', 'value': 'x'},
          };
    final conn = _FakeConn('board-g');
    StudioCompositionSeam.register(
      call: calls.call,
      clientHost: () => null,
      openOrigin: (id) async => conn.live = true,
    );
    final hooks = StudioCompositionSeam.hooksFor(
      clientHost: () => _FakeHost(<mk.KernelClientConnection>[conn]),
    )!;
    const origin = <String, dynamic>{'connection': 'board-g'};

    await hooks.resolveDefinition('ui://app', origin);
    conn.live = false; // the board dropped; the next use re-opens it
    await hooks.resolveDefinition('ui://app', origin);

    expect(calls.tools.where((t) => t == 'mcp.read_resource').length, 2,
        reason: 'a device that rebooted with new UI necessarily got a new '
            'connection first — that is the one invalidation point');
  });

  test('c13 the AUTHORING runtime also gets all four (bundle surface)',
      () async {
    final calls = _Calls();
    StudioCompositionSeam.register(
        call: calls.call, clientHost: () => null);

    // The reference multi-origin bundle is a STUDIO bundle, so it renders on
    // the vendored fork runtime — a different Dart type from the served
    // surface's. Wiring only the served one leaves the very screen the profile
    // exists for showing its fallbacks.
    final runtime = studio.MCPUIRuntime();
    await runtime.initialize(<String, dynamic>{
      'type': 'page',
      'content': <String, dynamic>{'type': 'text', 'value': ''},
    });
    final renderer = runtime.engine!.renderer;
    expect(renderer.definitionResolver, isNull, reason: 'precondition');

    applyCompositionHooksToStudioRuntime(
        runtime, StudioCompositionSeam.hooksFor());

    expect(renderer.definitionResolver, isNotNull);
    expect(renderer.originToolCaller, isNotNull);
    expect(renderer.originResourceWatcher, isNotNull);
    expect(renderer.originResourceReader, isNotNull);
  });

  test('c14 the registered clientHost is used when a surface passes none',
      () async {
    final calls = _Calls();
    final opened = <String>[];
    StudioCompositionSeam.register(
      call: calls.call,
      // ONE registry for the whole host: the composed screen and a standalone
      // open must see the same connection, or each re-dials a device that
      // serves a single peer.
      clientHost: () =>
          _FakeHost(<mk.KernelClientConnection>[_FakeConn('board-h')]),
      openOrigin: (id) async => opened.add(id),
    );

    await StudioCompositionSeam.hooksFor()!.readResource(
        <String, dynamic>{'connection': 'board-h'}, 'sensor://t');

    expect(opened, isEmpty,
        reason: 'the seam-registered registry already holds this origin');
  });
}
