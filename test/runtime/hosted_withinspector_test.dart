/// Isolation: does the inspector's ALWAYS-ON `withInspector` MetaData
/// wrapping break button tool actions on the HOSTED runtime?
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';

Widget _wrap(Widget child, Map<String, dynamic> node) {
  return MetaData(
    metaData: node,
    behavior: HitTestBehavior.translucent,
    child: child,
  );
}

void main() {
  testWidgets('hosted + withInspector: button tool action still fires',
      (tester) async {
    final runtime = MCPUIRuntime.withInspector(widgetWrapper: _wrap);
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
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => runtime.buildUI(
              context: context,
              onToolCall: (tool, params) => calls.add(tool),
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
        reason: 'withInspector wrapping must not break tool actions');
  });
}
