/// The Audit page lists the host dispatch log newest first and filters it.
library;

import 'dart:convert';

import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/src/apps/ops/state/providers.dart';
import 'package:appplayer_studio/src/apps/ops/ui/audit/audit_page.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, List<Map<String, Object?>> log) async {
  final host = mk.InProcessKernelServerHost(name: 'audit', version: '0');
  final reg = BuiltinToolRegistry(host);
  reg.addTool(
    name: 'studio.debug.dispatch_log',
    description: '',
    inputSchema: const <String, dynamic>{'type': 'object'},
    handler:
        (_) async => mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode({'count': log.length, 'entries': log}),
            ),
          ],
        ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [opsToolServerProvider.overrideWithValue(reg)],
      child: const MaterialApp(home: Scaffold(body: AuditPage())),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, Object?> _entry(String tool, int second, {bool error = false}) => {
  'ts': DateTime.utc(2026, 9, 25, 10, 0, second).toIso8601String(),
  'tool': tool,
  'durationMs': 3,
  'isError': error,
  'args': {'apiKey': '[redacted]'},
};

void main() {
  testWidgets('lists calls newest first', (tester) async {
    await _pump(tester, [
      _entry('workspace_list', 1),
      _entry('member_create_agent', 2),
    ]);
    final first = tester.getTopLeft(find.text('member_create_agent')).dy;
    final second = tester.getTopLeft(find.text('workspace_list')).dy;
    expect(first, lessThan(second));
  });

  testWidgets('filters by tool name and by failure', (tester) async {
    await _pump(tester, [
      _entry('workspace_list', 1),
      _entry('member_create_agent', 2, error: true),
      _entry('task_create', 3),
    ]);
    await tester.enterText(find.byKey(const ValueKey('audit.filter')), 'task');
    await tester.pumpAndSettle();
    expect(find.text('task_create'), findsOneWidget);
    expect(find.text('workspace_list'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('audit.filter')), '');
    await tester.tap(find.byKey(const ValueKey('audit.errorsOnly')));
    await tester.pumpAndSettle();
    expect(find.text('member_create_agent'), findsOneWidget);
    expect(find.text('task_create'), findsNothing);
    expect(find.text('ERR'), findsOneWidget);
  });

  testWidgets('a row expands to its arguments', (tester) async {
    await _pump(tester, [_entry('config_set_llm_provider', 1)]);
    await tester.tap(find.text('config_set_llm_provider'));
    await tester.pumpAndSettle();
    expect(find.textContaining('[redacted]'), findsOneWidget);
  });

  testWidgets('an empty log says so', (tester) async {
    await _pump(tester, const []);
    expect(find.text('No tool calls yet.'), findsOneWidget);
  });
}
