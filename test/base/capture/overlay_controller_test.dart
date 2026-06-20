/// r29-r34: Unit tests for [OverlayController] — the ValueNotifier-backed
/// list manager. Pure logic, no disk I/O, no timers.
///
/// Also covers the overlay MCP tool handlers
/// (studio.overlay.push / remove / clear / list) via InProcessKernelServerHost
/// following the pattern in test/base/install/builtin_tools_gate_test.dart.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_studio/src/base/capture/overlay/overlay_controller.dart';
import 'package:appplayer_studio/src/base/capture/overlay/overlay_models.dart';
import 'package:appplayer_studio/src/base/capture/overlay/overlay_tools.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

OverlaySpec _buildSpec(String id, String kind) =>
    OverlaySpec.fromJson(id, <String, dynamic>{'kind': kind});

Map<String, dynamic> _callResult(mk.KernelToolResult r) {
  final text = (r.content.first as mk.KernelTextContent).text;
  return jsonDecode(text) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // r29 ------------------------------------------------------------------
  group('r29: OverlayController.push — id generation and value update', () {
    test('first push returns "ov_1" and value has 1 entry', () {
      final ctrl = OverlayController();
      final id = ctrl.push((id) => _buildSpec(id, 'subtitle'));
      expect(id, 'ov_1');
      expect(ctrl.value, hasLength(1));
      expect(ctrl.value.first.id, 'ov_1');
    });

    test('sequential pushes generate ascending ids', () {
      final ctrl = OverlayController();
      final id1 = ctrl.push((id) => _buildSpec(id, 'subtitle'));
      final id2 = ctrl.push((id) => _buildSpec(id, 'watermark'));
      final id3 = ctrl.push((id) => _buildSpec(id, 'check_mark'));
      expect(id1, 'ov_1');
      expect(id2, 'ov_2');
      expect(id3, 'ov_3');
      expect(ctrl.value, hasLength(3));
    });

    test('id assigned to spec matches the returned id', () {
      final ctrl = OverlayController();
      String? captured;
      final returned = ctrl.push((id) {
        captured = id;
        return _buildSpec(id, 'pulse_dot');
      });
      expect(returned, captured);
      expect(ctrl.value.first.id, captured);
    });
  });

  // r30 ------------------------------------------------------------------
  group('r30: OverlayController.remove', () {
    test('remove returns true and entry is gone', () {
      final ctrl = OverlayController();
      final id = ctrl.push((id) => _buildSpec(id, 'watermark'));
      final removed = ctrl.remove(id);
      expect(removed, isTrue);
      expect(ctrl.value, isEmpty);
    });

    test('remove for non-existent id returns false and list is unchanged', () {
      final ctrl = OverlayController();
      ctrl.push((id) => _buildSpec(id, 'subtitle'));
      final removed = ctrl.remove('ov_999');
      expect(removed, isFalse);
      expect(ctrl.value, hasLength(1));
    });

    test('remove only removes the matching entry', () {
      final ctrl = OverlayController();
      final id1 = ctrl.push((id) => _buildSpec(id, 'subtitle'));
      final id2 = ctrl.push((id) => _buildSpec(id, 'watermark'));
      ctrl.remove(id1);
      expect(ctrl.value, hasLength(1));
      expect(ctrl.value.first.id, id2);
    });
  });

  // r31 ------------------------------------------------------------------
  group('r31: OverlayController.clear', () {
    test('clear empties the list', () {
      final ctrl = OverlayController();
      ctrl.push((id) => _buildSpec(id, 'subtitle'));
      ctrl.push((id) => _buildSpec(id, 'watermark'));
      ctrl.clear();
      expect(ctrl.value, isEmpty);
    });

    test('clear on already-empty list does not throw', () {
      final ctrl = OverlayController();
      expect(() => ctrl.clear(), returnsNormally);
      expect(ctrl.value, isEmpty);
    });
  });

  // r32 ------------------------------------------------------------------
  group('r32: OverlayController.snapshotJson', () {
    test('snapshotJson returns one map per entry with expected keys', () {
      final ctrl = OverlayController();
      ctrl.push((id) => _buildSpec(id, 'check_mark'));
      ctrl.push((id) => _buildSpec(id, 'cross_mark'));
      final snap = ctrl.snapshotJson();
      expect(snap, hasLength(2));
      expect(snap[0]['id'], 'ov_1');
      expect(snap[0]['kind'], 'check_mark');
      expect(snap[1]['id'], 'ov_2');
      expect(snap[1]['kind'], 'cross_mark');
    });

    test('snapshotJson returns empty list when no overlays', () {
      final ctrl = OverlayController();
      expect(ctrl.snapshotJson(), isEmpty);
    });
  });

  // r33 ------------------------------------------------------------------
  group(
    'r33: OverlayController notifies listeners on push / remove / clear',
    () {
      test('push triggers notifyListeners', () {
        final ctrl = OverlayController();
        var notified = 0;
        ctrl.addListener(() => notified++);
        ctrl.push((id) => _buildSpec(id, 'subtitle'));
        expect(notified, 1);
      });

      test('remove triggers notifyListeners only when an entry is removed', () {
        final ctrl = OverlayController();
        final id = ctrl.push((id) => _buildSpec(id, 'subtitle'));
        var notified = 0;
        ctrl.addListener(() => notified++);

        ctrl.remove('no-such-id'); // should NOT notify (value unchanged)
        expect(notified, 0);

        ctrl.remove(id); // SHOULD notify
        expect(notified, 1);
      });

      test('clear triggers notifyListeners only when list is non-empty', () {
        final ctrl = OverlayController();
        var notified = 0;
        ctrl.addListener(() => notified++);

        ctrl.clear(); // empty → no notification
        expect(notified, 0);

        ctrl.push((id) => _buildSpec(id, 'watermark'));
        notified = 0;
        ctrl.clear(); // non-empty → notification
        expect(notified, 1);
      });
    },
  );

  // r34 ------------------------------------------------------------------
  group('r34: MCP overlay tools via InProcessKernelServerHost', () {
    late OverlayController ctrl;
    late mk.InProcessKernelServerHost boot;

    setUp(() {
      ctrl = OverlayController();
      boot = mk.InProcessKernelServerHost();
      registerOverlayTools(boot, controller: ctrl);
    });

    test('studio.overlay.push registers the tool and push succeeds', () async {
      final toolNames = boot.toolDefinitions.map((t) => t.name).toSet();
      expect(toolNames.contains('studio.overlay.push'), isTrue);
      expect(toolNames.contains('studio.overlay.remove'), isTrue);
      expect(toolNames.contains('studio.overlay.clear'), isTrue);
      expect(toolNames.contains('studio.overlay.list'), isTrue);
    });

    test(
      'studio.overlay.push handler returns ok:true with overlayId',
      () async {
        final result = await boot.callTool(
          'studio.overlay.push',
          <String, dynamic>{'kind': 'subtitle'},
        );
        final j = _callResult(result);
        expect(j['ok'], isTrue);
        expect(j['overlayId'], isA<String>());
        expect(ctrl.value, hasLength(1));
      },
    );

    test('studio.overlay.push with unknown kind returns ok:false', () async {
      final result = await boot.callTool(
        'studio.overlay.push',
        <String, dynamic>{'kind': 'glow_ring'},
      );
      final j = _callResult(result);
      expect(j['ok'], isFalse);
      expect(j['error'], isA<String>());
    });

    test('studio.overlay.remove handler removes pushed overlay', () async {
      // First push.
      final pushResult = await boot.callTool(
        'studio.overlay.push',
        <String, dynamic>{'kind': 'watermark'},
      );
      final pushJ = _callResult(pushResult);
      final overlayId = pushJ['overlayId'] as String;
      expect(ctrl.value, hasLength(1));

      // Now remove.
      final removeResult = await boot.callTool(
        'studio.overlay.remove',
        <String, dynamic>{'overlayId': overlayId},
      );
      final removeJ = _callResult(removeResult);
      expect(removeJ['ok'], isTrue);
      expect(removeJ['removed'], isTrue);
      expect(ctrl.value, isEmpty);
    });

    test(
      'studio.overlay.remove with missing overlayId returns error',
      () async {
        final result = await boot.callTool(
          'studio.overlay.remove',
          <String, dynamic>{},
        );
        final j = _callResult(result);
        expect(j['ok'], isFalse);
      },
    );

    test('studio.overlay.clear removes all overlays', () async {
      await boot.callTool('studio.overlay.push', <String, dynamic>{
        'kind': 'subtitle',
      });
      await boot.callTool('studio.overlay.push', <String, dynamic>{
        'kind': 'watermark',
      });
      expect(ctrl.value, hasLength(2));

      final result = await boot.callTool(
        'studio.overlay.clear',
        <String, dynamic>{},
      );
      final j = _callResult(result);
      expect(j['ok'], isTrue);
      expect(ctrl.value, isEmpty);
    });

    test('studio.overlay.list returns correct count and entries', () async {
      await boot.callTool('studio.overlay.push', <String, dynamic>{
        'kind': 'subtitle',
      });
      await boot.callTool('studio.overlay.push', <String, dynamic>{
        'kind': 'check_mark',
      });

      final result = await boot.callTool(
        'studio.overlay.list',
        <String, dynamic>{},
      );
      final j = _callResult(result);
      expect(j['count'], 2);
      expect((j['entries'] as List), hasLength(2));
    });
  });
}
