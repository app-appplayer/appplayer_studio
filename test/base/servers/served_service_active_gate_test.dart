/// Active-tab gate for [ServedServiceBody] — the regression lock for two
/// market-connected service tabs rendering the SAME screen.
///
/// The workspace keeps every open tab alive in an IndexedStack, and
/// `flutter_mcp_ui_runtime`'s ThemeManager / WidgetCache / navigatorKey are
/// PROCESS singletons — so two co-mounted served surfaces would fight over
/// those singletons and render each other's UI. The fix gates the render on
/// `WorkspaceTabActiveScope`: only the ACTIVE service tab mounts its runtime.
///
/// This test proves the gate WITHOUT the runtime: an inactive body must never
/// even reach its connection (no `readResource`), so it cannot build a runtime
/// that would contend for the singletons. An active body reads `ui://app`.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:appplayer_studio/src/base/main/chrome_bridge.dart'
    show WorkspaceTabActiveScope;
import 'package:appplayer_studio/src/base/servers/served_service.dart';
import 'package:brain_kernel/brain_kernel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake served connection that records every resource read.
class _RecordingConn implements KernelClientConnection {
  _RecordingConn(this.id);

  @override
  final String id;
  final List<String> reads = <String>[];

  @override
  bool get isConnected => true;

  @override
  Future<KernelReadResourceResult> readResource(String uri) async {
    reads.add(uri);
    // A minimal, themeless page — enough for the read to succeed; the render
    // outcome is irrelevant to the gate this test asserts.
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
  _Host(this._conns);
  final List<_RecordingConn> _conns;

  @override
  Iterable<KernelClientConnection> get connections => _conns;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('${i.memberName}');
}

Widget _wrap({required bool active, required Widget child}) => MaterialApp(
      home: Scaffold(
        body: WorkspaceTabActiveScope(active: active, child: child),
      ),
    );

void main() {
  testWidgets('an INACTIVE service tab never reads its connection', (
    tester,
  ) async {
    final conn = _RecordingConn('B');
    await tester.pumpWidget(
      _wrap(
        active: false,
        child: ServedServiceBody(clientHost: _Host([conn]), connectionId: 'B'),
      ),
    );
    // Let any microtask that a render would have scheduled run.
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      conn.reads,
      isEmpty,
      reason: 'inactive tab must not mount its runtime — no resource read, so '
          'it cannot contend for the singleton runtime state',
    );
  });

  testWidgets('an ACTIVE service tab reads ui://app', (tester) async {
    final conn = _RecordingConn('A');
    await tester.pumpWidget(
      _wrap(
        active: true,
        child: ServedServiceBody(clientHost: _Host([conn]), connectionId: 'A'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(conn.reads, contains('ui://app'));
  });

  testWidgets(
    'closing a served tab bumps themeReinjectTick so survivors re-inject',
    (tester) async {
      final tick = ValueNotifier<int>(0);
      final host = _Host([_RecordingConn('A')]);
      // Mount, then replace with an empty tree so the body disposes (tab close).
      await tester.pumpWidget(
        _wrap(
          active: true,
          child: ServedServiceBody(
            clientHost: host,
            connectionId: 'A',
            themeReinjectTick: tick,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      final before = tick.value;
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      expect(
        tick.value,
        greaterThan(before),
        reason: 'a closing served tab must signal survivors that the shared '
            'singleton ThemeManager was reset',
      );
      tick.dispose();
    },
  );

  testWidgets(
    'two co-mounted tabs: only the ACTIVE one reads (no entanglement)',
    (tester) async {
      final a = _RecordingConn('A');
      final b = _RecordingConn('B');
      final host = _Host([a, b]);
      // Both bodies alive at once (the IndexedStack reality), but distinct
      // active flags — exactly the two-market-service-tabs scenario.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: <Widget>[
                WorkspaceTabActiveScope(
                  active: true,
                  child: ServedServiceBody(
                    key: const ValueKey('A'),
                    clientHost: host,
                    connectionId: 'A',
                  ),
                ),
                WorkspaceTabActiveScope(
                  active: false,
                  child: ServedServiceBody(
                    key: const ValueKey('B'),
                    clientHost: host,
                    connectionId: 'B',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(a.reads, contains('ui://app'), reason: 'active A renders');
      expect(b.reads, isEmpty, reason: 'inactive B stays gated — no shared render');
    },
  );
}
