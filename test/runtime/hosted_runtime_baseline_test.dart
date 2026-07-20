/// Baseline for the HOSTED flutter_mcp_ui_runtime (what the inspector
/// preview actually uses) — does buildUI(onToolCall:) fire for a
/// button tool action?
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';

void main() {
  testWidgets('HOSTED runtime: button tool action reaches onToolCall',
      (tester) async {
    final runtime = MCPUIRuntime();
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
    expect(calls, hasLength(1), reason: 'hosted runtime must fire onToolCall');
  });
}
