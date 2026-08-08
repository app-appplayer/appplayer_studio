/// Does the vendored `lottieSurface()` actually draw?
///
/// In the live studio `lottieAnimation` came back empty after everything else
/// had been excluded — the JSON (a file with an independent witness), the
/// `bundle://` path (an image from the same uri drew), the capability (it is
/// declared), the bytes (a reader forced to answer) and the layout (an
/// explicit 200×200 box). This asks the surface directly, with no app around
/// it, so the answer cannot be about wiring.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:appplayer_studio/runtime.dart'
    show SurfaceAssets, SurfaceEvents;
import 'package:appplayer_studio/src/base/media/host_media.dart'
    show lottieSurface;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The document AppPlayer's own capability probe requires every cut — a red
/// square animating left to right.
const Map<String, dynamic> _knownGoodLottie = <String, dynamic>{
  'v': '5.7.4', 'fr': 30, 'ip': 0, 'op': 60, 'w': 200, 'h': 200,
  'nm': 'probe', 'ddd': 0, 'assets': <dynamic>[],
  'layers': <dynamic>[
    <String, dynamic>{
      'ddd': 0, 'ind': 1, 'ty': 4, 'nm': 'box', 'sr': 1,
      'ks': <String, dynamic>{
        'o': <String, dynamic>{'a': 0, 'k': 100},
        'r': <String, dynamic>{'a': 0, 'k': 0},
        'p': <String, dynamic>{
          'a': 1,
          'k': <dynamic>[
            <String, dynamic>{
              't': 0, 's': <dynamic>[40, 100, 0], 'e': <dynamic>[160, 100, 0],
              'i': <String, dynamic>{'x': <dynamic>[0.5], 'y': <dynamic>[1]},
              'o': <String, dynamic>{'x': <dynamic>[0.5], 'y': <dynamic>[0]},
            },
            <String, dynamic>{'t': 60, 's': <dynamic>[160, 100, 0]},
          ],
        },
        'a': <String, dynamic>{'a': 0, 'k': <dynamic>[0, 0, 0]},
        'ss': null,
        's': <String, dynamic>{'a': 0, 'k': <dynamic>[100, 100, 100]},
      },
      'ao': 0,
      'shapes': <dynamic>[
        <String, dynamic>{
          'ty': 'gr',
          'it': <dynamic>[
            <String, dynamic>{
              'ty': 'rc', 'd': 1,
              's': <String, dynamic>{'a': 0, 'k': <dynamic>[60, 60]},
              'p': <String, dynamic>{'a': 0, 'k': <dynamic>[0, 0]},
              'r': <String, dynamic>{'a': 0, 'k': 0},
            },
            <String, dynamic>{
              'ty': 'fl',
              'c': <String, dynamic>{'a': 0, 'k': <dynamic>[1, 0, 0, 1]},
              'o': <String, dynamic>{'a': 0, 'k': 100},
            },
            <String, dynamic>{
              'ty': 'tr',
              'p': <String, dynamic>{'a': 0, 'k': <dynamic>[0, 0]},
              'a': <String, dynamic>{'a': 0, 'k': <dynamic>[0, 0]},
              's': <String, dynamic>{'a': 0, 'k': <dynamic>[100, 100]},
              'r': <String, dynamic>{'a': 0, 'k': 0},
              'o': <String, dynamic>{'a': 0, 'k': 100},
            },
          ],
        },
      ],
      'ip': 0, 'op': 60, 'st': 0, 'bm': 0,
    },
  ],
};

void main() {
  testWidgets('the surface builds a widget and reports no error',
      (tester) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(_knownGoodLottie)));
    final errors = <Object>[];

    final surface = lottieSurface();
    late Widget? built;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (ctx) {
          built = surface(
            ctx,
            <String, dynamic>{'source': 'bundle://anim.json'},
            SurfaceEvents((name, payload) => errors.add(payload)),
            SurfaceAssets((ref) async => bytes),
          );
          return SizedBox(width: 200, height: 200, child: built);
        }),
      ),
    );
    // The bytes arrive asynchronously; the first frame is the loading state.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(built, isNotNull,
        reason: 'a null surface means the capability reads as absent');
    expect(errors, isEmpty, reason: 'the surface reported: $errors');
    // If the animation rasterises, a RawImage/CustomPaint subtree exists under
    // the box. Asserting on the reported error above is the load-bearing half;
    // this catches "built something that paints nothing".
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
