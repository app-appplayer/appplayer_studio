/// Unit tests for `studioToolDefinitions` — the null-safe wrapper around
/// `KernelServerHost.toolDefinitions`.
///
///   td1  null boot → empty list
///   td2  non-null boot with no tools → empty list
///   td3  non-null boot with tools → list of toJson() maps
library;

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/boot/tool_definitions_reader.dart';

void main() {
  group('studioToolDefinitions', () {
    // td1
    test('td1 null boot returns empty list', () {
      final result = studioToolDefinitions(null);
      expect(result, isEmpty);
    });

    // td2
    test('td2 boot with no registered tools returns empty list', () {
      // InProcessKernelServerHost is the lightweight variant
      // that does not start an HTTP server.
      final boot = mk.InProcessKernelServerHost();
      final result = studioToolDefinitions(boot);
      expect(result, isEmpty);
    });

    // td3
    test('td3 boot with a registered tool returns its toJson() map', () {
      final boot = mk.InProcessKernelServerHost();
      boot.addTool(
        name: 'test.ping',
        description: 'ping',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        handler:
            (_) async => mk.KernelToolResult(
              content: [mk.KernelTextContent(text: 'pong')],
              isError: false,
            ),
      );
      final defs = studioToolDefinitions(boot);
      expect(defs, hasLength(1));
      final def = defs.first;
      expect(def['name'], 'test.ping');
      expect(def.containsKey('description'), isTrue);
      expect(def.containsKey('inputSchema'), isTrue);
    });

    test('td3 multiple tools returns equal count', () {
      final boot = mk.InProcessKernelServerHost();
      for (var i = 0; i < 5; i++) {
        boot.addTool(
          name: 'tool.$i',
          description: 'tool $i',
          inputSchema: const <String, dynamic>{'type': 'object'},
          handler:
              (_) async => mk.KernelToolResult(
                content: [mk.KernelTextContent(text: 'ok')],
                isError: false,
              ),
        );
      }
      final defs = studioToolDefinitions(boot);
      expect(defs, hasLength(5));
      final names = defs.map((d) => d['name'] as String).toSet();
      for (var i = 0; i < 5; i++) {
        expect(names, contains('tool.$i'));
      }
    });
  });
}
