/// The studio ships the LGPL FFmpeg build, so no command may ask for x264;
/// H.264 comes from VideoToolbox on Apple Silicon and openh264 elsewhere, at
/// a quality translated from the CRF scale.
library;

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:appplayer_studio/src/base/capture/recorder/encoder_service.dart';
import 'package:appplayer_studio/src/base/capture/recorder/h264_encoder.dart';
import 'package:appplayer_studio/src/base/capture/recorder/video_edit_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encoder per platform', () {
    expect(h264EncoderFor(Abi.macosArm64), kVideoToolboxH264);
    expect(h264EncoderFor(Abi.macosX64), kOpenH264);
    expect(h264EncoderFor(Abi.windowsX64), kOpenH264);
    expect(h264EncoderFor(Abi.linuxX64), kOpenH264);
  });

  test('VideoToolbox quality follows the CRF scale, higher = better', () {
    String q(int crf) =>
        h264VideoArgs(crf: crf, encoder: kVideoToolboxH264).split(' ').last;
    expect(q(0), '100');
    expect(q(51), '1');
    expect(int.parse(q(18)), greaterThan(int.parse(q(23))));
    expect(
      h264VideoArgs(encoder: kVideoToolboxH264),
      h264VideoArgs(crf: kDefaultCrf, encoder: kVideoToolboxH264),
    );
  });

  test('openh264 pins its quantiser to the CRF value', () {
    expect(
      h264VideoArgs(crf: 20, encoder: kOpenH264),
      '-c:v libopenh264 -pix_fmt yuv420p -rc_mode quality -qmin 20 -qmax 20',
    );
  });

  test('an encoder the caller names gets FFmpeg crf', () {
    expect(
      h264VideoArgs(crf: 30, encoder: 'libvpx-vp9', pixelFormat: 'yuv420p'),
      '-c:v libvpx-vp9 -pix_fmt yuv420p -crf 30',
    );
  });

  test('no command builder asks for a GPL encoder', () {
    final commands = <String>[
      buildEncodeCommand(pattern: 'f_%06d.png', fps: 24, out: 'o.mp4'),
      buildTrimCommand(input: 'i.mp4', startSec: 0, output: 'o.mp4'),
      for (final f in <String>['mp4', 'webm', 'gif', 'webp'])
        buildConvertCommand(input: 'i.mp4', output: 'o.$f', format: f),
      buildZoomCommand(
        input: 'i.mp4',
        output: 'o.mp4',
        width: 640,
        height: 480,
        startSec: 0,
        endSec: 1,
      ),
    ];
    for (final c in commands) {
      expect(c, isNot(matches(RegExp(r'libx26[45]|libxvid|vidstab'))));
    }
  });

  test('the capture sources name no GPL encoder', () {
    final hits = <String>[
      for (final f in Directory(
        'lib/src/base/capture',
      ).listSync(recursive: true))
        if (f is File &&
            f.path.endsWith('.dart') &&
            RegExp(r'libx26[45]').hasMatch(f.readAsStringSync()))
          f.path,
    ];
    expect(hits, isEmpty);
  });
}
