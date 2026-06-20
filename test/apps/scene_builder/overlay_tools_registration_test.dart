/// `registerOverlayTools` — verifies the four `studio.overlay.*` MCP tools
/// are registered and that their handlers exercise the `OverlayController`
/// state correctly (push / remove / clear / list).
///
/// Uses `mk.InProcessKernelServerHost` (same pattern as
/// `builtin_tools_gate_test.dart`). `OverlayController` is a pure in-memory
/// value notifier — no Flutter engine needed.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_studio/src/base/capture/overlay/overlay_controller.dart';
import 'package:appplayer_studio/src/base/capture/overlay/overlay_tools.dart';

Map<String, dynamic> _json(mk.KernelToolResult result) {
  final text = result.content.whereType<mk.KernelTextContent>().first.text;
  return jsonDecode(text) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late mk.InProcessKernelServerHost boot;
  late OverlayController ctrl;

  setUp(() {
    ctrl = OverlayController();
    boot = mk.InProcessKernelServerHost();
    registerOverlayTools(boot, controller: ctrl);
  });

  // u1 — all four tools are registered.
  test('u1: all four overlay tools are registered', () {
    final names = boot.toolDefinitions.map((t) => t.name).toSet();
    expect(
      names,
      containsAll(<String>[
        'studio.overlay.push',
        'studio.overlay.remove',
        'studio.overlay.clear',
        'studio.overlay.list',
      ]),
    );
  });

  // u2 — overlay.push with a valid kind returns ok:true + overlayId.
  test(
    'u2: overlay.push valid subtitle returns ok:true and overlayId',
    () async {
      final result = await boot.callTool(
        'studio.overlay.push',
        <String, dynamic>{
          'kind': 'subtitle',
          'text': 'Hello',
          'target': <String, dynamic>{'screen': 'body'},
        },
      );
      final json = _json(result);
      expect(json['ok'], isTrue);
      expect(json['overlayId'], isA<String>());
      expect((json['overlayId'] as String), isNotEmpty);
    },
  );

  // u3 — overlay.push with unknown kind returns ok:false.
  test('u3: overlay.push with unknown kind returns ok:false', () async {
    final result = await boot.callTool('studio.overlay.push', <String, dynamic>{
      'kind': 'nonexistent_overlay_kind',
    });
    final json = _json(result);
    expect(json['ok'], isFalse);
    expect(json['error'], isA<String>());
  });

  // u4 — overlay.remove with a valid id returns ok:true + removed:true.
  test(
    'u4: overlay.remove with known id returns ok:true, removed:true',
    () async {
      final pushResult = await boot.callTool(
        'studio.overlay.push',
        <String, dynamic>{'kind': 'watermark', 'text': 'DEMO'},
      );
      final pushJson = _json(pushResult);
      final id = pushJson['overlayId'] as String;

      final removeResult = await boot.callTool(
        'studio.overlay.remove',
        <String, dynamic>{'overlayId': id},
      );
      final removeJson = _json(removeResult);
      expect(removeJson['ok'], isTrue);
      expect(removeJson['removed'], isTrue);
    },
  );

  // u4b — overlay.remove with unknown id returns removed:false.
  test('u4b: overlay.remove with unknown id returns removed:false', () async {
    final result = await boot.callTool(
      'studio.overlay.remove',
      <String, dynamic>{'overlayId': 'no_such_id'},
    );
    final json = _json(result);
    expect(json['ok'], isTrue);
    expect(json['removed'], isFalse);
  });

  // u5 — overlay.clear returns ok:true.
  test('u5: overlay.clear returns ok:true', () async {
    // Push two overlays first.
    await boot.callTool('studio.overlay.push', <String, dynamic>{
      'kind': 'subtitle',
    });
    await boot.callTool('studio.overlay.push', <String, dynamic>{
      'kind': 'watermark',
    });
    expect(ctrl.value, hasLength(2));

    final result = await boot.callTool(
      'studio.overlay.clear',
      const <String, dynamic>{},
    );
    final json = _json(result);
    expect(json['ok'], isTrue);
    expect(ctrl.value, isEmpty);
  });

  // u6 — overlay.list count matches pushed entries.
  test('u6: overlay.list count reflects pushed entries', () async {
    await boot.callTool('studio.overlay.push', <String, dynamic>{
      'kind': 'subtitle',
    });
    await boot.callTool('studio.overlay.push', <String, dynamic>{
      'kind': 'check_mark',
    });

    final result = await boot.callTool(
      'studio.overlay.list',
      const <String, dynamic>{},
    );
    final json = _json(result);
    expect(json['count'], 2);
    expect((json['entries'] as List), hasLength(2));
  });

  // u6b — overlay.list is empty after clear.
  test('u6b: overlay.list returns count 0 after clear', () async {
    await boot.callTool('studio.overlay.push', <String, dynamic>{
      'kind': 'pulse_dot',
    });
    await boot.callTool('studio.overlay.clear', const <String, dynamic>{});

    final result = await boot.callTool(
      'studio.overlay.list',
      const <String, dynamic>{},
    );
    final json = _json(result);
    expect(json['count'], 0);
  });

  // u7 — overlay.remove requires overlayId.
  test('u7: overlay.remove with empty overlayId returns ok:false', () async {
    final result = await boot.callTool(
      'studio.overlay.remove',
      <String, dynamic>{'overlayId': ''},
    );
    final json = _json(result);
    expect(json['ok'], isFalse);
    expect(json['error'], isA<String>());
  });
}
