/// Unit tests for `overlay_models.dart` pure logic:
/// - `overlayKindFromString` / `overlayKindToString` bijection
/// - `PositionRef.fromJson` / `toJson` round-trip for all five forms
/// - `OverlaySpec.fromJson` / `toJson`
/// - `parseHexColor` hex parsing
/// - `OverlayController` push / remove / clear / snapshotJson
library;

import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/capture/overlay/overlay_controller.dart';
import 'package:appplayer_studio/src/base/capture/overlay/overlay_models.dart';

void main() {
  // ---------------------------------------------------------------------------
  // overlayKindFromString / overlayKindToString
  // ---------------------------------------------------------------------------

  group('overlayKindFromString', () {
    // o1 — every canonical snake_case string maps to a non-null OverlayKind.
    test('o1: maps every canonical snake_case string', () {
      final cases = <String, OverlayKind>{
        'title_card': OverlayKind.titleCard,
        'subtitle': OverlayKind.subtitle,
        'step_indicator': OverlayKind.stepIndicator,
        'watermark': OverlayKind.watermark,
        'transition': OverlayKind.transition,
        'arrow_pointer': OverlayKind.arrowPointer,
        'speech_bubble': OverlayKind.speechBubble,
        'pulse_dot': OverlayKind.pulseDot,
        'connector_line': OverlayKind.connectorLine,
        'circle_highlight': OverlayKind.circleHighlight,
        'check_mark': OverlayKind.checkMark,
        'cross_mark': OverlayKind.crossMark,
        'highlighter': OverlayKind.highlighter,
        'box_outline': OverlayKind.boxOutline,
        'underline': OverlayKind.underline,
        'strikethrough': OverlayKind.strikethrough,
        'bracket': OverlayKind.bracket,
        'numbered_label': OverlayKind.numberedLabel,
        'floating_icon': OverlayKind.floatingIcon,
        'floating_image': OverlayKind.floatingImage,
      };
      for (final entry in cases.entries) {
        expect(
          overlayKindFromString(entry.key),
          entry.value,
          reason: '"${entry.key}" should map to ${entry.value}',
        );
      }
    });

    test('o1b: unknown string returns null', () {
      expect(overlayKindFromString('totally_unknown'), isNull);
      expect(overlayKindFromString(''), isNull);
    });

    // o2 — overlayKindToString is the inverse of overlayKindFromString.
    test('o2: overlayKindToString is inverse of overlayKindFromString', () {
      for (final kind in OverlayKind.values) {
        final str = overlayKindToString(kind);
        expect(
          overlayKindFromString(str),
          kind,
          reason: 'round-trip failed for $kind (got "$str")',
        );
      }
    });

    test('o2b: all 20 enum values have a toJson string', () {
      // The set size must equal the enum values count — no duplicate strings.
      final strings = OverlayKind.values.map(overlayKindToString).toSet();
      expect(strings, hasLength(OverlayKind.values.length));
    });
  });

  // ---------------------------------------------------------------------------
  // PositionRef.fromJson / toJson
  // ---------------------------------------------------------------------------

  group('PositionRef', () {
    // o3 — abs form: {abs: {x, y}} and {abs: {x, y, w, h}}.
    test('o3: fromJson abs — x/y only', () {
      final ref = PositionRef.fromJson(<String, Object?>{
        'abs': <String, Object?>{'x': 10.0, 'y': 20.0},
      });
      expect(ref.x, 10.0);
      expect(ref.y, 20.0);
      expect(ref.w, isNull);
      expect(ref.h, isNull);
      expect(ref.element, isNull);
    });

    test('o3b: fromJson abs — x/y/w/h', () {
      final ref = PositionRef.fromJson(<String, Object?>{
        'abs': <String, Object?>{'x': 5.0, 'y': 6.0, 'w': 100.0, 'h': 50.0},
      });
      expect(ref.x, 5.0);
      expect(ref.y, 6.0);
      expect(ref.w, 100.0);
      expect(ref.h, 50.0);
    });

    // o4 — element form: map and bare string.
    test('o4: fromJson element — map form', () {
      final ref = PositionRef.fromJson(<String, Object?>{
        'element': 'tool:addTool',
      });
      expect(ref.element, 'tool:addTool');
      expect(ref.x, isNull);
    });

    test('o4b: fromJson element — bare string convenience form', () {
      final ref = PositionRef.fromJson('some_element_id');
      expect(ref.element, 'some_element_id');
    });

    // o5 — metadata form.
    test('o5: fromJson metadata', () {
      final ref = PositionRef.fromJson(<String, Object?>{
        'metadata': 'uid:counter',
      });
      expect(ref.metadata, 'uid:counter');
      expect(ref.element, isNull);
    });

    // o6 — widget form.
    test('o6: fromJson widget', () {
      final ref = PositionRef.fromJson(<String, Object?>{
        'widget': 'chat-input',
      });
      expect(ref.widget, 'chat-input');
    });

    // o7 — screen form and unrecognised-input fallback.
    test('o7: fromJson screen', () {
      final ref = PositionRef.fromJson(<String, Object?>{'screen': 'body'});
      expect(ref.screen, 'body');
    });

    test(
      'o7b: fromJson fallback on unrecognised input returns screen:window',
      () {
        // null input — falls through to PositionRef.screen('window').
        final ref = PositionRef.fromJson(null);
        expect(ref.screen, 'window');
      },
    );

    // o8 — toJson round-trips for all five forms.
    test('o8: toJson round-trip abs (x/y only)', () {
      final original = PositionRef.abs(1.0, 2.0);
      final json = original.toJson();
      final restored = PositionRef.fromJson(json);
      expect(restored.x, 1.0);
      expect(restored.y, 2.0);
    });

    test('o8b: toJson round-trip abs (x/y/w/h)', () {
      final original = PositionRef.abs(1.0, 2.0, 30.0, 40.0);
      final json = original.toJson();
      final restored = PositionRef.fromJson(json);
      expect(restored.x, 1.0);
      expect(restored.y, 2.0);
      expect(restored.w, 30.0);
      expect(restored.h, 40.0);
    });

    test('o8c: toJson round-trip element', () {
      final original = PositionRef.element('my_element');
      final json = original.toJson();
      expect(json['element'], 'my_element');
      final restored = PositionRef.fromJson(json);
      expect(restored.element, 'my_element');
    });

    test('o8d: toJson round-trip metadata', () {
      final original = PositionRef.metadata('uid:btn');
      final json = original.toJson();
      final restored = PositionRef.fromJson(json);
      expect(restored.metadata, 'uid:btn');
    });

    test('o8e: toJson round-trip widget', () {
      final original = PositionRef.widget('chat-input');
      final json = original.toJson();
      final restored = PositionRef.fromJson(json);
      expect(restored.widget, 'chat-input');
    });

    test('o8f: toJson round-trip screen', () {
      final original = PositionRef.screen('left_panel');
      final json = original.toJson();
      final restored = PositionRef.fromJson(json);
      expect(restored.screen, 'left_panel');
    });
  });

  // ---------------------------------------------------------------------------
  // OverlaySpec.fromJson / toJson
  // ---------------------------------------------------------------------------

  group('OverlaySpec', () {
    // o9 — happy-path parse + round-trip.
    test('o9: fromJson parses kind, target, timing fields', () {
      final spec = OverlaySpec.fromJson('ov_1', <String, dynamic>{
        'kind': 'subtitle',
        'target': <String, dynamic>{'screen': 'body'},
        'text': 'Hello world',
        'appearMs': 100,
        'stayMs': 2000,
        'fadeMs': 150,
      });
      expect(spec.id, 'ov_1');
      expect(spec.kind, OverlayKind.subtitle);
      expect(spec.target?.screen, 'body');
      expect(spec.appearMs, 100);
      expect(spec.stayMs, 2000);
      expect(spec.fadeMs, 150);
      expect(spec.props['text'], 'Hello world');
    });

    test('o9b: fromJson defaults timing fields when absent', () {
      final spec = OverlaySpec.fromJson('ov_2', <String, dynamic>{
        'kind': 'watermark',
      });
      expect(spec.appearMs, 200);
      expect(spec.stayMs, 0);
      expect(spec.fadeMs, 300);
    });

    test('o9c: fromJson parses targets list', () {
      final spec = OverlaySpec.fromJson('ov_3', <String, dynamic>{
        'kind': 'connector_line',
        'targets': <Map<String, dynamic>>[
          <String, dynamic>{'element': 'a'},
          <String, dynamic>{'element': 'b'},
        ],
      });
      expect(spec.targets, hasLength(2));
      expect(spec.targets!.first.element, 'a');
      expect(spec.targets!.last.element, 'b');
    });

    test('o9d: toJson round-trip preserves kind + props', () {
      final spec = OverlaySpec.fromJson('ov_4', <String, dynamic>{
        'kind': 'check_mark',
        'color': '#FF0000',
        'stayMs': 500,
      });
      final json = spec.toJson();
      expect(json['id'], 'ov_4');
      expect(json['kind'], 'check_mark');
      expect(json['color'], '#FF0000');
      expect(json['stayMs'], 500);
    });

    // o10 — unknown kind throws FormatException.
    test('o10: fromJson throws FormatException on unknown kind', () {
      expect(
        () => OverlaySpec.fromJson('x', <String, dynamic>{
          'kind': 'exploding_star',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('o10b: fromJson throws FormatException when kind is missing', () {
      expect(
        () => OverlaySpec.fromJson('x', <String, dynamic>{}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // parseHexColor
  // ---------------------------------------------------------------------------

  group('parseHexColor', () {
    // o11 — valid RGB ('#RRGGBB').
    test('o11: valid #RRGGBB returns Color with full alpha', () {
      final c = parseHexColor('#FF0000');
      expect(c, isNotNull);
      expect(c!.red, 255);
      expect(c.green, 0);
      expect(c.blue, 0);
    });

    test('o11b: valid 8-char hex (AARRGGBB) round-trip', () {
      // parseHexColor treats 8-char as AARRGGBB (Flutter Color constructor).
      // 'ffFF0000' → alpha=0xff, R=0xFF, G=0x00, B=0x00.
      final c = parseHexColor('#ffFF0000');
      expect(c, isNotNull);
      expect(c!.red, 255);
    });

    test('o11c: null input returns null', () {
      expect(parseHexColor(null), isNull);
    });

    test('o11d: empty string returns null', () {
      expect(parseHexColor(''), isNull);
    });

    test('o11e: too-short hex returns null', () {
      expect(parseHexColor('#FFF'), isNull);
    });

    test('o11f: non-hex chars return null', () {
      expect(parseHexColor('#GGHHII'), isNull);
    });

    test('o11g: without # prefix — 6-char treated as RRGGBB (alpha ff)', () {
      final c = parseHexColor('0000FF');
      expect(c, isNotNull);
      expect(c!.blue, 255);
    });
  });

  // ---------------------------------------------------------------------------
  // OverlayController
  // ---------------------------------------------------------------------------

  group('OverlayController', () {
    late OverlayController ctrl;

    setUp(() {
      ctrl = OverlayController();
    });

    // o12 — push adds an entry and returns an id.
    test('o12: push returns a non-empty id', () {
      final id = ctrl.push(
        (id) => OverlaySpec.fromJson(id, <String, dynamic>{'kind': 'subtitle'}),
      );
      expect(id, isNotEmpty);
      expect(ctrl.value, hasLength(1));
    });

    test('o12b: successive pushes assign distinct ids', () {
      final id1 = ctrl.push(
        (id) => OverlaySpec.fromJson(id, <String, dynamic>{'kind': 'subtitle'}),
      );
      final id2 = ctrl.push(
        (id) =>
            OverlaySpec.fromJson(id, <String, dynamic>{'kind': 'watermark'}),
      );
      expect(id1, isNot(id2));
      expect(ctrl.value, hasLength(2));
    });

    test('o12c: remove by known id returns true and reduces count', () {
      final id = ctrl.push(
        (id) =>
            OverlaySpec.fromJson(id, <String, dynamic>{'kind': 'pulse_dot'}),
      );
      expect(ctrl.value, hasLength(1));
      final removed = ctrl.remove(id);
      expect(removed, isTrue);
      expect(ctrl.value, isEmpty);
    });

    test('o12d: remove by unknown id returns false, list unchanged', () {
      ctrl.push(
        (id) => OverlaySpec.fromJson(id, <String, dynamic>{'kind': 'subtitle'}),
      );
      final removed = ctrl.remove('no_such_id');
      expect(removed, isFalse);
      expect(ctrl.value, hasLength(1));
    });

    test('o12e: clear removes all entries', () {
      ctrl.push(
        (id) => OverlaySpec.fromJson(id, <String, dynamic>{'kind': 'subtitle'}),
      );
      ctrl.push(
        (id) =>
            OverlaySpec.fromJson(id, <String, dynamic>{'kind': 'watermark'}),
      );
      expect(ctrl.value, hasLength(2));
      ctrl.clear();
      expect(ctrl.value, isEmpty);
    });

    test('o12f: clear on empty controller is a no-op', () {
      expect(() => ctrl.clear(), returnsNormally);
      expect(ctrl.value, isEmpty);
    });

    test(
      'o12g: snapshotJson returns serialisable maps matching pushed entries',
      () {
        ctrl.push(
          (id) =>
              OverlaySpec.fromJson(id, <String, dynamic>{'kind': 'check_mark'}),
        );
        ctrl.push(
          (id) => OverlaySpec.fromJson(id, <String, dynamic>{
            'kind': 'subtitle',
            'text': 'hi',
          }),
        );
        final snap = ctrl.snapshotJson();
        expect(snap, hasLength(2));
        expect(snap.first['kind'], 'check_mark');
        expect(snap.last['kind'], 'subtitle');
        expect(snap.last['text'], 'hi');
      },
    );

    test('o12h: remove preserves remaining entries in order', () {
      final id1 = ctrl.push(
        (id) => OverlaySpec.fromJson(id, <String, dynamic>{'kind': 'subtitle'}),
      );
      final id2 = ctrl.push(
        (id) =>
            OverlaySpec.fromJson(id, <String, dynamic>{'kind': 'watermark'}),
      );
      final id3 = ctrl.push(
        (id) =>
            OverlaySpec.fromJson(id, <String, dynamic>{'kind': 'pulse_dot'}),
      );
      ctrl.remove(id2);
      expect(ctrl.value.map((s) => s.id).toList(), <String>[id1, id3]);
    });
  });
}
