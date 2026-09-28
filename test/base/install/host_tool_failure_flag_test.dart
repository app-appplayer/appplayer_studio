/// Host `studio.*` tools that answer a failure in their JSON body carry the
/// MCP `isError` flag too. They reported `{ok:false}` with the flag unset,
/// so MCP clients that read the flag took a refusal for success.
library;

import 'dart:convert';

import 'package:appplayer_studio/src/base/install/capability_tools.dart'
    show registerFormCapability;
import 'package:appplayer_studio/src/base/install/tool_call_guard.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';

mk.KernelToolResult _body(Map<String, Object?> b) => mk.KernelToolResult(
  content: <mk.KernelContent>[mk.KernelTextContent(text: jsonEncode(b))],
);

void main() {
  late FailureFlaggingServerHost host;
  setUp(() {
    host = FailureFlaggingServerHost(
      mk.InProcessKernelServerHost(name: 'studio', version: '0'),
    );
    void add(String name, Map<String, Object?> body) => host.addTool(
      name: name,
      description: name,
      inputSchema: const <String, dynamic>{'type': 'object'},
      handler: (_) async => _body(body),
    );
    add('refuses', {'ok': false, 'error': 'unknown overlay kind: x'});
    add('errors', {'error': 'shell not mounted'});
    add('succeeds', {'ok': true, 'removed': true});
    add('plain', {'count': 0});
  });

  test('failure bodies are flagged', () async {
    expect((await host.callTool('refuses', {})).isError, isTrue);
    expect((await host.callTool('errors', {})).isError, isTrue);
  });

  test('successes are left alone', () async {
    expect((await host.callTool('succeeds', {})).isError, isNot(true));
    expect((await host.callTool('plain', {})).isError, isNot(true));
  });

  test('the wrapper forwards the rest to the host', () {
    expect(host.name, 'studio');
    expect(
      host.toolDefinitions.map((d) => d.name),
      containsAll(<String>['refuses', 'errors', 'succeeds', 'plain']),
    );
  });

  group('capability registry endpoint (checkArguments)', () {
    late mk.HostToolRegistry registry;
    late FailureFlaggingServerHost endpoint;

    setUp(() {
      endpoint = FailureFlaggingServerHost(
        mk.InProcessKernelServerHost(name: 'studio', version: '0'),
        checkArguments: true,
      );
      registry = mk.HostToolRegistry(
        endpoint: endpoint,
        attachToDispatcher: (_, _) {},
        detachFromDispatcher: (_) {},
      );
      registerFormCapability(registry);
    });

    Map<String, dynamic> body(mk.KernelToolResult r) =>
        jsonDecode((r.content.first as mk.KernelTextContent).text)
            as Map<String, dynamic>;

    test('a missing required field is named, not a cast error', () async {
      final r = await endpoint.callTool('form.validate', {});
      expect(r.isError, isTrue);
      expect(body(r)['code'], 'invalidArguments');
      expect(
        (body(r)['errors'] as List).cast<Map>().map((e) => e['field']),
        contains('documentId'),
      );
    });

    test('a wrongly typed field is named, not a cast error', () async {
      final r = await endpoint.callTool('form.validate', {'documentId': 5});
      expect(body(r)['code'], 'invalidArguments');
      expect((body(r)['errors'] as List).cast<Map>().single['problem'], 'type');
    });

    test('a value beyond the capability enum reaches the capability', () async {
      // form.render has always taken `png`; the endpoint checks shape only.
      final r = await endpoint.callTool('form.render', {
        'documentId': 'nope',
        'format': 'png',
      });
      expect(body(r)['code'], isNot('invalidArguments'));
    });

    test('a well-formed call still reaches the capability', () async {
      final r = await endpoint.callTool('form.list_templates', {});
      expect(r.isError, isNot(true));
      expect(body(r)['templates'], isA<List>());
    });
  });
}
