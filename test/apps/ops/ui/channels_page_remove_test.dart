/// Removing a channel must say so when its stored credentials survive.
/// Drives the real page over a real host tool registry whose `channel.*`
/// tools answer the way the vault and connector map do.
library;

import 'dart:convert';

import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/src/apps/ops/state/providers.dart';
import 'package:appplayer_studio/src/apps/ops/ui/channels/channels_page.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

mk.KernelToolResult _json(Map<String, dynamic> body, {bool error = false}) =>
    mk.KernelToolResult(
      content: <mk.KernelContent>[mk.KernelTextContent(text: jsonEncode(body))],
      isError: error,
    );

/// Host with one stored-only credential `mail` (no live connector).
class _Host {
  _Host({this.vaultFails = false, this.disconnectFails = false}) {
    host = mk.InProcessKernelServerHost(name: 'ops-test', version: '0');
    final reg = BuiltinToolRegistry(host);
    const schema = <String, dynamic>{'type': 'object'};
    reg.addTool(
      name: 'channel.list',
      description: '',
      inputSchema: schema,
      handler: (_) async => _json(<String, dynamic>{'channels': <dynamic>[]}),
    );
    reg.addTool(
      name: 'channel.credential_ids',
      description: '',
      inputSchema: schema,
      handler: (_) async => _json(<String, dynamic>{'ids': ids.toList()}),
    );
    reg.addTool(
      name: 'channel.disconnect',
      description: '',
      inputSchema: schema,
      handler:
          (args) async =>
              disconnectFails
                  ? _json(<String, dynamic>{
                    'code': 'channel.stop_failed',
                  }, error: true)
                  : _json(<String, dynamic>{
                    'code': 'channel.not_found',
                  }, error: true),
    );
    reg.addTool(
      name: 'channel.credential_remove',
      description: '',
      inputSchema: schema,
      handler: (args) async {
        if (vaultFails) {
          return _json(<String, dynamic>{
            'ok': false,
            'error': 'keychain locked',
          }, error: true);
        }
        ids.remove(args['id']);
        return _json(<String, dynamic>{'ok': true});
      },
    );
    registry = reg;
  }

  final bool vaultFails;
  final bool disconnectFails;
  final Set<String> ids = <String>{'mail'};
  late final mk.InProcessKernelServerHost host;
  late final BuiltinToolRegistry registry;
}

Future<void> _pump(WidgetTester tester, _Host h) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [opsToolServerProvider.overrideWithValue(h.registry)],
      child: const MaterialApp(home: Scaffold(body: ChannelsPage())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('stored-only credential removes cleanly — no error shown', (
    tester,
  ) async {
    final h = _Host();
    await _pump(tester, h);
    expect(find.text('mail'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(h.ids, isEmpty);
    expect(find.text('mail'), findsNothing);
    expect(find.byKey(const ValueKey('channels.removeError')), findsNothing);
  });

  testWidgets('a vault failure is shown and the channel stays listed', (
    tester,
  ) async {
    final h = _Host(vaultFails: true);
    await _pump(tester, h);
    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(h.ids, contains('mail'));
    expect(find.text('mail'), findsOneWidget);
    final banner = find.byKey(const ValueKey('channels.removeError'));
    expect(banner, findsOneWidget);
    final text = tester.widget<Text>(banner).data!;
    expect(text, contains('credentials were not deleted'));
    expect(text, contains('keychain locked'));
  });

  testWidgets('a disconnect failure other than not-connected is shown', (
    tester,
  ) async {
    final h = _Host(disconnectFails: true);
    await _pump(tester, h);
    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    final text =
        tester
            .widget<Text>(find.byKey(const ValueKey('channels.removeError')))
            .data!;
    expect(text, contains('disconnect failed'));
    expect(text, contains('channel.stop_failed'));
  });
}
