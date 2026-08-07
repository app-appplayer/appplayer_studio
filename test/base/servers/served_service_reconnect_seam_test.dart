/// The seam between a served tab and the reconnect watch (spec 17 §7.6d).
///
/// The watch decides WHEN to dial; this view decides WHETHER anyone is waiting.
/// That is the whole scope rule — retrying is licensed by an open app and
/// bounded by it — so the mount/dispose pairing is not bookkeeping, it is the
/// contract. A missing release leaves a radio and a dial loop running for a tab
/// that closed; a missing hold means a dropped board is never dialled at all
/// and the user is back to the error screen with no way out.
///
/// Also locks the Retry defect: pressing Retry used to re-run the render, which
/// resolves the connection and throws the same error every time, so the button
/// the code pointed users at could not recover anything.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:appplayer_studio/src/base/servers/reconnect_watch.dart';
import 'package:appplayer_studio/src/base/servers/served_service.dart';
import 'package:brain_kernel/brain_kernel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Conn implements KernelClientConnection {
  _Conn(this.id, {required this.isConnected});

  @override
  final String id;

  @override
  bool isConnected;

  final List<String> reads = <String>[];

  @override
  Future<KernelReadResourceResult> readResource(String uri) async {
    reads.add(uri);
    return KernelReadResourceResult(
      contents: <KernelResourceContent>[
        KernelResourceContent(
          uri: uri,
          text: jsonEncode(<String, Object?>{
            'type': 'page',
            'content': <String, Object?>{'type': 'text', 'value': ''},
          }),
        ),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('${i.memberName}');
}

class _Host implements KernelClientHost {
  _Host(this.conns);
  final List<_Conn> conns;

  @override
  Iterable<KernelClientConnection> get connections => conns;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('${i.memberName}');
}

void main() {
  late List<String> dialled;
  late StudioReconnectWatch watch;
  late _Host host;
  late _Conn conn;

  setUp(() {
    dialled = <String>[];
    conn = _Conn('board', isConnected: false);
    host = _Host(<_Conn>[conn]);
    watch = StudioReconnectWatch(
      isLive: (id) => host.conns.any((c) => c.id == id && c.isConnected),
      dial: (id) async => dialled.add(id),
      // Long enough that nothing fires on its own inside a pumped frame — every
      // dial these tests observe is one the view asked for.
      detectInterval: const Duration(minutes: 10),
      retryInterval: const Duration(minutes: 10),
    );
  });

  tearDown(() => watch.dispose());

  Widget app() => MaterialApp(
        home: ServedServiceBody(
          clientHost: host,
          connectionId: 'board',
          reconnect: watch,
        ),
      );

  testWidgets('mounting holds the id and dialling starts at once',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(watch.held, contains('board'));
    expect(watch.stalledServers, <String>{'board'});
    // A tab that opens onto an already-dead connection is the common case —
    // waiting for the first detect tick would stall recovery for no reason.
    expect(dialled, <String>['board']);
  });

  testWidgets('disposing releases the id so nothing keeps dialling',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    dialled.clear();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(watch.held, isNot(contains('board')));
    expect(watch.stalledServers, isEmpty);
    watch.hintReachable('board');
    await tester.pump();
    expect(dialled, isEmpty, reason: 'a closed tab was still being dialled');
  });

  testWidgets('Retry asks for a dial instead of re-throwing the same error',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    dialled.clear();

    // The dead connection renders the actionable error the host promises.
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    // The wake resumes a loop parked on its interval, so the dial lands an
    // async turn later — pump until the microtasks it queues have run.
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }

    // Before the fix this only rebuilt the render future, which resolves the
    // connection and throws again — the press could not reach the dial at all.
    expect(dialled, <String>['board']);
  });

  testWidgets('a recovered connection re-renders with no second press',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    // Dead on mount: the render never got as far as reading anything.
    expect(find.text('Retry'), findsOneWidget);
    expect(conn.reads, isEmpty);

    // What the watch does when a dial succeeds: liveness flips, then it ticks.
    conn.isConnected = true;
    watch.hintReachable('board');
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    // The edge alone restarted the render — asserted by the read going out,
    // not by what the runtime managed to paint from it. Without the listener
    // the tab sits on its error until someone presses Retry, which is the
    // behaviour this axis exists to remove.
    expect(conn.reads, contains('ui://app'),
        reason: 'the connection came back and nothing re-read');
  });
}
