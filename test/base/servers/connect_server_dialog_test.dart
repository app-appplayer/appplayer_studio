/// Widget matrix for the Connect Server dialog — the tabbed Manual / Discover
/// surface. Manual is a transport-aware form that pops a [ConnectServerRequest];
/// Discover scans the wired sources and connects a picked board straight
/// through the host. Both halves are host-independent (the scan / connect seams
/// are injected typedefs), so the whole surface is covered here without a
/// kernel.
@TestOn('vm')
library;

import 'dart:async';

import 'package:appplayer_studio/src/base/servers/connect_server_dialog.dart';
import 'package:brain_kernel/brain_kernel.dart' show KernelTransportKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps a host with a single button that opens the dialog; the resolved
/// [ConnectServerRequest] (or null on cancel) lands in [box.value].
class _ResultBox {
  ConnectServerRequest? value;
  bool resolved = false;
}

Future<_ResultBox> _open(
  WidgetTester tester, {
  DiscoverScan? scan,
  ConnectDiscovered? connectDiscovered,
}) async {
  final box = _ResultBox();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              box.value = await showConnectServerDialog(
                context,
                scan: scan,
                connectDiscovered: connectDiscovered,
              );
              box.resolved = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return box;
}

/// A [TextField] located by its decoration label (labels are decoration text,
/// not child widgets, so `widgetWithText` misses them).
Finder _fieldByLabel(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label,
    );

Future<void> _selectTransport(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<KernelTransportKind>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  group('shape', () {
    testWidgets('no scan wired → manual form only, no tab chrome',
        (tester) async {
      await _open(tester);
      expect(find.text('Connect Server'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.widgetWithText(Tab, 'Discover'), findsNothing);
      // The manual form is present (transport selector + Connect).
      expect(find.byType(DropdownButtonFormField<KernelTransportKind>),
          findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    });

    testWidgets('scan wired → Manual + Discover tabs', (tester) async {
      await _open(tester, scan: () async => const <DiscoveredServer>[]);
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Manual'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Discover'), findsOneWidget);
    });
  });

  group('manual — http', () {
    testWidgets('valid URL pops a streamableHttp request with token + name',
        (tester) async {
      final box = await _open(tester);
      await tester.enterText(
          _fieldByLabel('MCP Server URL'), 'https://s.example.com/mcp');
      await tester.enterText(
          _fieldByLabel('Access token (optional)'), 'bearer-xyz');
      await tester.enterText(
          _fieldByLabel('Display name (optional)'), 'My Server');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      final req = box.value;
      expect(req, isNotNull);
      expect(req!.transport, KernelTransportKind.streamableHttp);
      expect(req.endpoint, 'https://s.example.com/mcp');
      expect(req.accessToken, 'bearer-xyz');
      expect(req.name, 'My Server');
    });

    testWidgets('empty name / token collapse to null', (tester) async {
      final box = await _open(tester);
      await tester.enterText(
          _fieldByLabel('MCP Server URL'), 'http://localhost:6270/mcp');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
      expect(box.value!.accessToken, isNull);
      expect(box.value!.name, isNull);
    });

    testWidgets('invalid URL surfaces an error and keeps the dialog open',
        (tester) async {
      final box = await _open(tester);
      await tester.enterText(_fieldByLabel('MCP Server URL'), 'not-a-url');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid http(s) server URL.'), findsOneWidget);
      expect(box.resolved, isFalse);
      expect(find.text('Connect Server'), findsOneWidget);
    });
  });

  group('manual — stdio', () {
    testWidgets('switching to stdio swaps URL for command + args fields',
        (tester) async {
      await _open(tester);
      await _selectTransport(tester, 'stdio');
      expect(_fieldByLabel('Command'), findsOneWidget);
      expect(_fieldByLabel('Arguments (optional)'), findsOneWidget);
      expect(_fieldByLabel('MCP Server URL'), findsNothing);
    });

    testWidgets('empty command is rejected', (tester) async {
      final box = await _open(tester);
      await _selectTransport(tester, 'stdio');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Choose the server executable.'), findsOneWidget);
      expect(box.resolved, isFalse);
    });

    testWidgets('command + whitespace-split args pop a stdio request',
        (tester) async {
      final box = await _open(tester);
      await _selectTransport(tester, 'stdio');
      await tester.enterText(
          _fieldByLabel('Command'), '/usr/local/bin/my-server');
      await tester.enterText(
          _fieldByLabel('Arguments (optional)'), '--port  9000   --verbose');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      final req = box.value!;
      expect(req.transport, KernelTransportKind.stdio);
      expect(req.command, '/usr/local/bin/my-server');
      expect(req.args, <String>['--port', '9000', '--verbose']);
      expect(req.endpoint, isNull);
    });
  });

  group('discover', () {
    Future<void> toDiscover(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(Tab, 'Discover'));
      await tester.pumpAndSettle();
    }

    testWidgets('pending scan shows the scanning spinner', (tester) async {
      final gate = Completer<List<DiscoveredServer>>();
      await _open(tester, scan: () => gate.future);
      await tester.tap(find.widgetWithText(Tab, 'Discover'));
      await tester.pump(); // enter the tab; scan() starts, stays pending
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Scanning…'), findsOneWidget);
      gate.complete(const <DiscoveredServer>[]); // release for teardown
      await tester.pumpAndSettle();
    });

    testWidgets('empty result shows the actionable empty state',
        (tester) async {
      await _open(tester, scan: () async => const <DiscoveredServer>[]);
      await toDiscover(tester);
      expect(
        find.textContaining('No servers found'),
        findsOneWidget,
      );
    });

    testWidgets('results render as source-tagged tiles', (tester) async {
      await _open(
        tester,
        scan: () async => const <DiscoveredServer>[
          DiscoveredServer(
            source: 'mdns',
            name: 'Lab Board',
            detail: '192.168.0.10:6270',
            raw: <String, dynamic>{},
          ),
          DiscoveredServer(
            source: 'ble',
            name: 'Wrist Sensor',
            detail: 'dev-1',
            raw: <String, dynamic>{},
          ),
        ],
      );
      await toDiscover(tester);
      expect(find.text('Lab Board'), findsOneWidget);
      expect(find.text('mdns · 192.168.0.10:6270'), findsOneWidget);
      expect(find.text('Wrist Sensor'), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(2));
    });

    testWidgets('tapping a tile connects it and closes the dialog',
        (tester) async {
      DiscoveredServer? connected;
      final box = await _open(
        tester,
        scan: () async => const <DiscoveredServer>[
          DiscoveredServer(
            source: 'mdns',
            name: 'Lab Board',
            detail: 'host:6270',
            raw: <String, dynamic>{'id': 'acme.lab'},
          ),
        ],
        connectDiscovered: (s) async => connected = s,
      );
      await toDiscover(tester);
      await tester.tap(find.text('Lab Board'));
      await tester.pumpAndSettle();

      expect(connected, isNotNull);
      expect(connected!.raw['id'], 'acme.lab');
      expect(find.text('Connect Server'), findsNothing); // dialog closed
      // Discovered connect happens in-dialog: no request returned to caller.
      expect(box.value, isNull);
      expect(box.resolved, isTrue);
    });

    testWidgets('a failed connect surfaces the error and keeps the dialog',
        (tester) async {
      await _open(
        tester,
        scan: () async => const <DiscoveredServer>[
          DiscoveredServer(
            source: 'usb',
            name: 'Serial Board',
            detail: '/dev/cu.usbmodem1',
            raw: <String, dynamic>{},
          ),
        ],
        connectDiscovered: (_) async => throw StateError('board busy'),
      );
      await toDiscover(tester);
      await tester.tap(find.text('Serial Board'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Connect failed:'), findsOneWidget);
      expect(find.text('Connect Server'), findsOneWidget); // still open
    });

    testWidgets('rescan re-invokes the scan seam', (tester) async {
      var scans = 0;
      await _open(
        tester,
        scan: () async {
          scans++;
          return const <DiscoveredServer>[];
        },
      );
      await toDiscover(tester);
      expect(scans, 1);
      await tester.tap(find.byTooltip('Rescan'));
      await tester.pumpAndSettle();
      expect(scans, 2);
    });

    testWidgets('a scan error surfaces the failure', (tester) async {
      await _open(
        tester,
        scan: () async => throw StateError('no radio'),
      );
      await toDiscover(tester);
      expect(find.textContaining('Scan failed:'), findsOneWidget);
    });
  });
}
