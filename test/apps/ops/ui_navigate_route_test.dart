/// `ui_navigate` accepts exactly the sidebar routes the Ops shell renders,
/// and a refused call answers a clean message (no stack dump).
library;

import 'dart:convert';

import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/src/apps/ops/ops_shell.dart' show OpsRoute;
import 'package:appplayer_studio/src/apps/ops/tools/ui_debug_tools.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late mk.InProcessKernelServerHost host;

  setUp(() {
    host = mk.InProcessKernelServerHost(name: 'ops', version: '0');
    const UiDebugTools().registerOn(BuiltinToolRegistry(host));
  });

  Future<(bool, Map<String, dynamic>)> call(String route) async {
    final r = await host.callTool('ui_navigate', {'route': route});
    final text = (r.content.first as mk.KernelTextContent).text;
    return (r.isError == true, jsonDecode(text) as Map<String, dynamic>);
  }

  test('every shell route is accepted', () async {
    for (final r in OpsRoute.values) {
      final (isError, body) = await call(r.id);
      expect(isError, isFalse, reason: r.id);
      expect(body['route'], r.id);
    }
  });

  test('an unknown route is refused with a clean message', () async {
    final (isError, body) = await call('nope_route');
    expect(isError, isTrue);
    expect(body['error'], contains('unknown route "nope_route"'));
    expect(body.containsKey('stack'), isFalse);
  });

  test('the description lists the shell routes', () {
    final def = host.toolDefinitions.firstWhere((d) => d.name == 'ui_navigate');
    for (final r in OpsRoute.values) {
      expect(def.description, contains(r.id));
    }
  });
}
