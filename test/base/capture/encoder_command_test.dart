/// Unit tests for `buildEncodeCommand` — the pure ffmpeg command-line
/// builder behind `EncoderService.encode`. Covers the video-only path
/// (unchanged behavior) and the audio-mux path (narration / music).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/capture/recorder/encoder_service.dart';

void main() {
  const pattern = '/rec/frame_%06d.png';
  const out = '/rec/out.mp4';

  group('buildEncodeCommand — video only (unchanged path)', () {
    test('no audio → simple -vf pad, no filter_complex / no audio codec', () {
      final cmd = buildEncodeCommand(pattern: pattern, fps: 24, out: out);
      expect(cmd, contains('-framerate 24'));
      expect(cmd, contains('-i "$pattern"'));
      expect(cmd, contains('-vf "pad=ceil(iw/2)*2:ceil(ih/2)*2"'));
      expect(cmd, contains('"$out"'));
      expect(cmd, isNot(contains('-filter_complex')));
      expect(cmd, isNot(contains('-c:a')));
      expect(cmd, isNot(contains('-shortest')));
    });

    test('crf is injected when provided', () {
      final cmd = buildEncodeCommand(
        pattern: pattern,
        fps: 24,
        out: out,
        crf: 20,
      );
      expect(cmd, contains('-crf 20'));
    });

    test('empty-path tracks are dropped → falls back to video-only', () {
      final cmd = buildEncodeCommand(
        pattern: pattern,
        fps: 24,
        out: out,
        audioTracks: const <Map<String, dynamic>>[
          <String, dynamic>{'path': ''},
        ],
      );
      expect(cmd, isNot(contains('-filter_complex')));
      expect(cmd, contains('-vf "pad'));
    });
  });

  group('buildEncodeCommand — single audio track', () {
    test('muxes one track with adelay/volume defaults + AAC + shortest', () {
      final cmd = buildEncodeCommand(
        pattern: pattern,
        fps: 30,
        out: out,
        audioTracks: const <Map<String, dynamic>>[
          <String, dynamic>{'path': '/a/narration.m4a'},
        ],
      );
      expect(cmd, contains('-i "/a/narration.m4a"'));
      expect(cmd, contains('-filter_complex'));
      expect(cmd, contains('[0:v]pad=ceil(iw/2)*2:ceil(ih/2)*2[v]'));
      expect(cmd, contains('[1:a]adelay=0:all=1,volume=1.0[a0]'));
      expect(cmd, contains('-map "[v]"'));
      expect(cmd, contains('-map "[a0]"'));
      expect(cmd, contains('-c:a aac'));
      expect(cmd, contains('-shortest'));
      expect(cmd, isNot(contains('amix')));
    });

    test('honours startMs and volume', () {
      final cmd = buildEncodeCommand(
        pattern: pattern,
        fps: 24,
        out: out,
        audioTracks: const <Map<String, dynamic>>[
          <String, dynamic>{
            'path': '/a/music.mp3',
            'startMs': 2000,
            'volume': 0.2,
          },
        ],
      );
      expect(cmd, contains('adelay=2000:all=1,volume=0.2'));
    });
  });

  group('buildEncodeCommand — multiple tracks (mix)', () {
    test('two tracks → amix inputs=2 mapped to [aout]', () {
      final cmd = buildEncodeCommand(
        pattern: pattern,
        fps: 24,
        out: out,
        audioTracks: const <Map<String, dynamic>>[
          <String, dynamic>{'path': '/a/voice.m4a'},
          <String, dynamic>{'path': '/a/bgm.mp3', 'volume': 0.15},
        ],
      );
      expect(cmd, contains('-i "/a/voice.m4a"'));
      expect(cmd, contains('-i "/a/bgm.mp3"'));
      expect(cmd, contains('[a0]'));
      expect(cmd, contains('volume=0.15[a1]'));
      expect(
        cmd,
        contains(
          '[a0][a1]amix=inputs=2:dropout_transition=0:normalize=0[aout]',
        ),
      );
      expect(cmd, contains('-map "[aout]"'));
    });
  });
}
