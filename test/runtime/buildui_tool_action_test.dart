/// Fork regression — `MCPUIRuntime.buildUI(onToolCall:)` must register the
/// default tool executor on the ENGINE's action handler (post-init dispatch
/// path), not the pre-init local one. Upstream flutter_mcp_ui_runtime 0.5.1
/// registers on the local handler, so every `{"type":"tool"}` button action
/// dies with "Tool executor not found" and buttons silently no-op — found
/// live pressing a cloud-server app's Generate Report button in the
/// inspector preview (2026-07-13).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/runtime.dart' as rt;

void main() {
  testWidgets(
      'buildUI(onToolCall:) fires for a button tool action '
      '(engine-handler registration)', (tester) async {
    final runtime = rt.MCPUIRuntime();
    // Real-async zone: initialize touches real timers/futures that never
    // complete under the widget test's fake clock.
    await tester.runAsync(() => runtime.initialize(<String, dynamic>{
      'type': 'page',
      'title': 'T',
      'content': <String, dynamic>{
        'type': 'button',
        'label': 'Go',
        'onTap': <String, dynamic>{
          'type': 'tool',
          'tool': 'report.generate',
          'params': <String, dynamic>{'month': '2026-07'},
        },
      },
    }));

    final calls = <(String, Map<String, dynamic>)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => runtime.buildUI(
              context: context,
              onToolCall: (tool, params) => calls.add((tool, params)),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Go'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(calls, hasLength(1),
        reason: 'the tool action must reach onToolCall — a miss means the '
            'default executor was registered on the wrong action handler');
    expect(calls.single.$1, 'report.generate');
    expect(calls.single.$2['month'], '2026-07');
  });

  testWidgets(
      'application-type: page button tool action fires too '
      '(route-rendered page shares the engine handler)', (tester) async {
    final runtime = rt.MCPUIRuntime();
    await tester.runAsync(() => runtime.initialize(<String, dynamic>{
      'type': 'application',
      'title': 'App',
      'initialRoute': '/home',
      'routes': <String, dynamic>{'/home': 'ui://pages/home'},
    }, pageLoader: (uri) async => <String, dynamic>{
      'type': 'page',
      'title': 'Home',
      'content': <String, dynamic>{
        'type': 'button',
        'label': 'Go2',
        'onTap': <String, dynamic>{
          'type': 'tool',
          'tool': 'report.generate',
          'params': <String, dynamic>{'month': '2026-07'},
        },
      },
    }));

    final calls = <(String, Map<String, dynamic>)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => runtime.buildUI(
              context: context,
              onToolCall: (tool, params) => calls.add((tool, params)),
            ),
          ),
        ),
      ),
    );
    // Route page loads via a FutureBuilder — pump a few real frames.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Go2'), findsOneWidget,
        reason: 'route page must render its button');
    await tester.tap(find.text('Go2'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(calls, hasLength(1),
        reason: 'app-type page button must reach onToolCall');
    expect(calls.single.$1, 'report.generate');
  });
}
