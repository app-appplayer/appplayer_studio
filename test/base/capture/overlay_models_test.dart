/// r21-r30: Unit tests for [OverlayModels] — pure value types that need
/// no Flutter widgets, no timers, and no disk I/O.
///
/// Covers:
///   - PositionRef.fromJson for all 5 discriminants + bare-string convenience
///   - PositionRef.toJson round-trip
///   - overlayKindFromString / overlayKindToString round-trip for every kind
///   - OverlaySpec.fromJson happy path + unknown kind throws FormatException
///   - parseHexColor — valid 6-digit, valid 8-digit, invalid input
library;

import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/capture/overlay/overlay_models.dart';

void main() {
  // r21 ------------------------------------------------------------------
  group('r21: PositionRef.fromJson — abs discriminant', () {
    test('parses abs with x, y only', () {
      final ref = PositionRef.fromJson(<String, dynamic>{
        'abs': <String, dynamic>{'x': 10.0, 'y': 20.0},
      });
      expect(ref.x, 10.0);
      expect(ref.y, 20.0);
      expect(ref.w, isNull);
      expect(ref.h, isNull);
      expect(ref.element, isNull);
      expect(ref.screen, isNull);
    });

    test('parses abs with x, y, w, h', () {
      final ref = PositionRef.fromJson(<String, dynamic>{
        'abs': <String, dynamic>{'x': 5.0, 'y': 10.0, 'w': 100.0, 'h': 50.0},
      });
      expect(ref.x, 5.0);
      expect(ref.y, 10.0);
      expect(ref.w, 100.0);
      expect(ref.h, 50.0);
    });

    test('abs round-trips through toJson', () {
      final ref = PositionRef.abs(1.0, 2.0, 3.0, 4.0);
      final j = ref.toJson();
      final ref2 = PositionRef.fromJson(j);
      expect(ref2.x, 1.0);
      expect(ref2.y, 2.0);
      expect(ref2.w, 3.0);
      expect(ref2.h, 4.0);
    });
  });

  // r22 ------------------------------------------------------------------
  group('r22: PositionRef.fromJson — element discriminant', () {
    test('parses element string', () {
      final ref = PositionRef.fromJson(<String, dynamic>{
        'element': 'tool:addTool',
      });
      expect(ref.element, 'tool:addTool');
      expect(ref.x, isNull);
    });

    test('bare string convenience → element', () {
      final ref = PositionRef.fromJson('chat-input');
      expect(ref.element, 'chat-input');
    });

    test('element round-trips through toJson', () {
      final ref = PositionRef.element('my-id');
      final j = ref.toJson();
      final ref2 = PositionRef.fromJson(j);
      expect(ref2.element, 'my-id');
    });
  });

  // r23 ------------------------------------------------------------------
  group(
    'r23: PositionRef.fromJson — metadata, widget, screen discriminants',
    () {
      test('parses metadata key', () {
        final ref = PositionRef.fromJson(<String, dynamic>{
          'metadata': 'uid:counter-btn',
        });
        expect(ref.metadata, 'uid:counter-btn');
      });

      test('parses widget key', () {
        final ref = PositionRef.fromJson(<String, dynamic>{
          'widget': 'chat-panel',
        });
        expect(ref.widget, 'chat-panel');
      });

      test('parses screen key', () {
        final ref = PositionRef.fromJson(<String, dynamic>{'screen': 'body'});
        expect(ref.screen, 'body');
      });

      test('unknown map falls back to screen:window', () {
        final ref = PositionRef.fromJson(<String, dynamic>{'unknown': 'val'});
        expect(ref.screen, 'window');
      });

      test('null input falls back to screen:window', () {
        final ref = PositionRef.fromJson(null);
        expect(ref.screen, 'window');
      });

      test('screen round-trips through toJson', () {
        final ref = PositionRef.screen('left_panel');
        final j = ref.toJson();
        final ref2 = PositionRef.fromJson(j);
        expect(ref2.screen, 'left_panel');
      });
    },
  );

  // r24 ------------------------------------------------------------------
  group('r24: overlayKindFromString / overlayKindToString round-trip', () {
    final allKinds = <String, OverlayKind>{
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
      'slide': OverlayKind.slide,
      'cursor': OverlayKind.cursor,
    };

    for (final entry in allKinds.entries) {
      test('${entry.key} round-trips', () {
        final kind = overlayKindFromString(entry.key);
        expect(kind, entry.value);
        expect(overlayKindToString(kind!), entry.key);
      });
    }

    test('unknown string returns null', () {
      expect(overlayKindFromString('totally_unknown'), isNull);
    });

    // Natural-name aliases resolve to canonical kinds (one-way — they do
    // not round-trip back through overlayKindToString).
    final aliases = <String, OverlayKind>{
      'presentation': OverlayKind.slide,
      'logo': OverlayKind.floatingImage,
      'image': OverlayKind.floatingImage,
      'icon': OverlayKind.floatingIcon,
      'caption': OverlayKind.subtitle,
      'title': OverlayKind.titleCard,
      'check': OverlayKind.checkMark,
      'highlight': OverlayKind.circleHighlight,
      'mouse': OverlayKind.cursor,
      'pointer': OverlayKind.cursor,
    };
    for (final entry in aliases.entries) {
      test('alias "${entry.key}" → ${entry.value}', () {
        expect(overlayKindFromString(entry.key), entry.value);
      });
    }
  });

  // r25 ------------------------------------------------------------------
  group('r25: OverlaySpec.fromJson — happy path', () {
    test('minimal spec with kind only uses defaults', () {
      final spec = OverlaySpec.fromJson('ov_1', <String, dynamic>{
        'kind': 'subtitle',
      });
      expect(spec.id, 'ov_1');
      expect(spec.kind, OverlayKind.subtitle);
      expect(spec.target, isNull);
      expect(spec.targets, isNull);
      expect(spec.appearMs, 200);
      expect(spec.stayMs, 0);
      expect(spec.fadeMs, 300);
      expect(spec.props, isEmpty);
    });

    test('spec with lifecycle timings', () {
      final spec = OverlaySpec.fromJson('ov_2', <String, dynamic>{
        'kind': 'watermark',
        'appearMs': 0,
        'stayMs': 5000,
        'fadeMs': 800,
        'text': 'demo',
      });
      expect(spec.appearMs, 0);
      expect(spec.stayMs, 5000);
      expect(spec.fadeMs, 800);
      expect(spec.props['text'], 'demo');
    });

    test('spec with target field', () {
      final spec = OverlaySpec.fromJson('ov_3', <String, dynamic>{
        'kind': 'arrow_pointer',
        'target': <String, dynamic>{
          'abs': <String, dynamic>{'x': 50.0, 'y': 75.0},
        },
      });
      expect(spec.target, isNotNull);
      expect(spec.target!.x, 50.0);
      expect(spec.target!.y, 75.0);
    });

    test('spec with targets list', () {
      final spec = OverlaySpec.fromJson('ov_4', <String, dynamic>{
        'kind': 'connector_line',
        'targets': <dynamic>[
          <String, dynamic>{'screen': 'body'},
          <String, dynamic>{'element': 'btn-a'},
        ],
      });
      expect(spec.targets, hasLength(2));
      expect(spec.targets![0].screen, 'body');
      expect(spec.targets![1].element, 'btn-a');
    });
  });

  // r26 ------------------------------------------------------------------
  group('r26: OverlaySpec.fromJson — unknown kind throws FormatException', () {
    test('throws FormatException with unknown kind', () {
      expect(
        () => OverlaySpec.fromJson('ov_x', <String, dynamic>{
          'kind': 'glow_ring',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when kind key is missing', () {
      expect(
        () => OverlaySpec.fromJson('ov_x', <String, dynamic>{}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // r27 ------------------------------------------------------------------
  group('r27: OverlaySpec.toJson — round-trip', () {
    test('toJson produces kind string that fromJson accepts', () {
      final original = OverlaySpec.fromJson('ov_5', <String, dynamic>{
        'kind': 'check_mark',
        'appearMs': 100,
        'stayMs': 2000,
        'fadeMs': 400,
        'color': '#ff0000',
      });
      final j = original.toJson();
      expect(j['id'], 'ov_5');
      expect(j['kind'], 'check_mark');
      expect(j['appearMs'], 100);
      expect(j['stayMs'], 2000);
      expect(j['fadeMs'], 400);
      expect(j['color'], '#ff0000');
    });
  });

  // r28 ------------------------------------------------------------------
  group('r28: parseHexColor', () {
    test('parses valid 6-digit hex (no alpha) with full opacity', () {
      final c = parseHexColor('#ff0000');
      expect(c, isNotNull);
      // ff + ff0000 → 0xffff0000 = opaque red
      expect(c, const Color(0xffff0000));
    });

    test('parses valid 8-digit hex (with alpha)', () {
      final c = parseHexColor('#80ff0000');
      expect(c, isNotNull);
      expect(c, const Color(0x80ff0000));
    });

    test(
      'works without the # prefix... wait, # is required by the function signature',
      () {
        // The function strips '#' with replaceFirst; a string without '#'
        // leaves the 6-char form → prepends 'ff' → 8 chars → parses correctly.
        final c = parseHexColor('00ff00');
        expect(c, isNotNull);
        expect(c, const Color(0xff00ff00));
      },
    );

    test('returns null for null input', () {
      expect(parseHexColor(null), isNull);
    });

    test('returns null for empty string', () {
      expect(parseHexColor(''), isNull);
    });

    test('returns null for malformed hex', () {
      expect(parseHexColor('#gg0000'), isNull);
    });

    test('returns null for too-short hex (5 digits after stripping #)', () {
      expect(parseHexColor('#ff00'), isNull);
    });
  });
}
