/// Unit tests for the pure ffmpeg command builders behind
/// `VideoEditService` — trim & concat of existing video files.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/capture/recorder/video_edit_service.dart';

void main() {
  group('buildTrimCommand', () {
    test('start + end → output-side -ss/-to, re-encode, aac', () {
      final cmd = buildTrimCommand(
        input: '/v/in.mp4',
        startSec: 1.5,
        endSec: 4.25,
        output: '/v/out.mp4',
      );
      expect(cmd, contains('-i "/v/in.mp4"'));
      expect(cmd, contains('-ss 1.500'));
      expect(cmd, contains('-to 4.250'));
      expect(cmd, contains('-c:v libx264'));
      expect(cmd, contains('-pix_fmt yuv420p'));
      expect(cmd, contains('-c:a aac'));
      expect(cmd, contains('"/v/out.mp4"'));
    });

    test('no endSec → no -to (trims to clip end)', () {
      final cmd = buildTrimCommand(
        input: '/v/in.mp4',
        startSec: 2,
        output: '/v/out.mp4',
      );
      expect(cmd, contains('-ss 2.000'));
      expect(cmd, isNot(contains('-to ')));
    });

    test('crf injected when set', () {
      final cmd = buildTrimCommand(
        input: '/v/in.mp4',
        startSec: 0,
        output: '/v/out.mp4',
        crf: 20,
      );
      expect(cmd, contains('-crf 20'));
    });
  });

  group('buildConcatListFile', () {
    test('one file line per clip, in order', () {
      final body = buildConcatListFile(<String>['/a/1.mp4', '/a/2.mp4']);
      expect(body, "file '/a/1.mp4'\nfile '/a/2.mp4'");
    });

    test('escapes single quotes in paths', () {
      final body = buildConcatListFile(<String>["/a/it's.mp4"]);
      expect(body, "file '/a/it'\\''s.mp4'");
    });
  });

  group('buildConcatCommand', () {
    test('concat demuxer, stream-copy', () {
      final cmd = buildConcatCommand(
        listPath: '/tmp/list.txt',
        output: '/v/final.mp4',
      );
      expect(cmd, contains('-f concat'));
      expect(cmd, contains('-safe 0'));
      expect(cmd, contains('-i "/tmp/list.txt"'));
      expect(cmd, contains('-c copy'));
      expect(cmd, contains('"/v/final.mp4"'));
    });
  });

  group('buildConvertCommand — web export', () {
    test('webm → VP9 + Opus', () {
      final cmd = buildConvertCommand(
        input: '/v/in.mp4',
        output: '/v/o.webm',
        format: 'webm',
        crf: 32,
      );
      expect(cmd, contains('-c:v libvpx-vp9'));
      expect(cmd, contains('-crf 32 -b:v 0'));
      expect(cmd, contains('-c:a libopus'));
      expect(cmd, contains('"/v/o.webm"'));
    });

    test('gif → palettegen/paletteuse (clean colors), default fps', () {
      final cmd = buildConvertCommand(
        input: '/v/in.mp4',
        output: '/v/o.gif',
        format: 'gif',
      );
      expect(cmd, contains('-filter_complex'));
      expect(cmd, contains('fps=15'));
      expect(cmd, contains('palettegen'));
      expect(cmd, contains('paletteuse'));
    });

    test('webp → animated libwebp, looped, with scale', () {
      final cmd = buildConvertCommand(
        input: '/v/in.mp4',
        output: '/v/o.webp',
        format: 'webp',
        width: 480,
      );
      expect(cmd, contains('-c:v libwebp'));
      expect(cmd, contains('-loop 0'));
      expect(cmd, contains('scale=480:-1'));
    });

    test('mp4 (default) → libx264 + aac', () {
      final cmd = buildConvertCommand(
        input: '/v/in.webm',
        output: '/v/o.mp4',
        format: 'mp4',
      );
      expect(cmd, contains('-c:v libx264'));
      expect(cmd, contains('-c:a aac'));
    });
  });

  group('buildZoomExpr — trapezoid z(t)', () {
    test('flat outside the window, peak inside', () {
      final z = buildZoomExpr(startSec: 1, endSec: 3, zoom: 1.6, rampSec: 0.4);
      // Nested-if trapezoid: ramp boundaries 1, 1.4, 2.6, 3; peak 1.6000.
      expect(z, contains('lt(t,1.000)'));
      expect(z, contains('lt(t,1.400)'));
      expect(z, contains('lt(t,2.600)'));
      expect(z, contains('lt(t,3.000)'));
      expect(z, contains('1.6000'));
    });
  });

  group('buildZoomCommand — click zoom', () {
    test('time-varying crop toward focus, scaled back to source size', () {
      final cmd = buildZoomCommand(
        input: '/v/in.mp4',
        output: '/v/o.mp4',
        width: 1280,
        height: 720,
        startSec: 1,
        endSec: 3,
        zoom: 1.8,
        focusX: 0.25,
        focusY: 0.75,
      );
      expect(cmd, contains('crop=w='));
      expect(cmd, contains('floor(in_w/'));
      expect(cmd, contains('*0.2500')); // focusX offset
      expect(cmd, contains('*0.7500')); // focusY offset
      expect(cmd, contains('scale=1280:720'));
      expect(cmd, contains('-c:a copy'));
    });

    test('focus clamped to 0..1', () {
      final cmd = buildZoomCommand(
        input: '/v/in.mp4',
        output: '/v/o.mp4',
        width: 100,
        height: 100,
        startSec: 0,
        endSec: 2,
        focusX: 1.9,
        focusY: -0.5,
      );
      expect(cmd, contains('*1.0000'));
      expect(cmd, contains('*0.0000'));
    });
  });
}
