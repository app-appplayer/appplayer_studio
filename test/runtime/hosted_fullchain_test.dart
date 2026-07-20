/// Full live-inspector composition on the HOSTED runtime:
/// application-type + pageLoader + withInspector wrapper +
/// device-frame chain (SizedBox → FittedBox → InteractiveViewer).
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';

Widget _wrap(Widget child, Map<String, dynamic> node) => MetaData(
      metaData: node,
      behavior: HitTestBehavior.translucent,
      child: child,
    );

void main() {
  testWidgets('hosted full inspector chain: button fires', (tester) async {
    final runtime = MCPUIRuntime.withInspector(widgetWrapper: _wrap);
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
            'label': 'Go',
            'onTap': <String, dynamic>{
              'type': 'tool',
              'tool': 'report.generate',
              'params': <String, dynamic>{'month': '2026-07'},
            },
          },
        }));
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => InteractiveViewer(
              minScale: 0.1,
              maxScale: 5.0,
              boundaryMargin: const EdgeInsets.all(200),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: 393,
                    height: 852,
                    child: runtime.buildUI(
                      context: context,
                      onToolCall: (tool, params) => calls.add(tool),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Go'), findsOneWidget);
    await tester.tap(find.text('Go'), warnIfMissed: true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, hasLength(1),
        reason: 'full chain must deliver the tap to the button');
  });
}
