/// Render test for the synthetic `cursor` overlay — proves the painter
/// actually draws (non-transparent pixels at the tip) and that a static
/// `target` parks the cursor where it is placed. The cursor is the
/// recorder's substitute for the OS pointer (which the RepaintBoundary
/// capture cannot see), so "does it draw" is the load-bearing check.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/capture/overlay/overlay_controller.dart';
import 'package:appplayer_studio/src/base/capture/overlay/overlay_layer.dart';
import 'package:appplayer_studio/src/base/capture/overlay/overlay_models.dart';

void main() {
  testWidgets('cursor overlay paints opaque pixels at its tip', (tester) async {
    final controller =
        OverlayController()..push(
          (id) => OverlaySpec(
            id: id,
            kind: OverlayKind.cursor,
            target: PositionRef.abs(150, 150),
            appearMs: 0,
            stayMs: 1000,
            fadeMs: 0,
          ),
        );

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          child: SizedBox(
            width: 300,
            height: 300,
            child: OverlayLayer(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    int opaque = 0;
    int width = 0;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      width = image.width;
      final bytes =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      // Sample a box just below-right of the tip (the arrow body) — the
      // cursor fills that region, so at least one pixel must be opaque.
      for (var dy = 2; dy < 18; dy++) {
        for (var dx = 0; dx < 14; dx++) {
          final int i = ((150 + dy) * width + (150 + dx)) * 4;
          if (_alpha(bytes, i) > 40) opaque++;
        }
      }
    });
    expect(
      opaque,
      greaterThan(0),
      reason: 'cursor should draw pixels at its target',
    );
  });

  testWidgets('no cursor pixels far from the tip', (tester) async {
    final controller =
        OverlayController()..push(
          (id) => OverlaySpec(
            id: id,
            kind: OverlayKind.cursor,
            target: PositionRef.abs(150, 150),
            appearMs: 0,
            stayMs: 1000,
            fadeMs: 0,
          ),
        );
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          child: SizedBox(
            width: 300,
            height: 300,
            child: OverlayLayer(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    int alpha = 255;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      // Top-left corner is far from a cursor parked at (150,150).
      alpha = _alpha(bytes, (10 * image.width + 10) * 4);
    });
    expect(alpha, lessThan(10));
  });
}

int _alpha(ByteData bytes, int rgbaOffset) => bytes.getUint8(rgbaOffset + 3);
