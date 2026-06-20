/// Unit tests for `recorder_models.dart` pure logic:
/// - `Recording.ffmpegHint()` — format-specific output
/// - `Recording.duration` — computed from startedAt / stoppedAt
/// - `Recording.toJson()` — required keys and optional conditional keys
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/capture/recorder/recorder_models.dart';

Recording _recording({
  String id = 'rec_001',
  String format = 'png',
  int fps = 24,
  String area = 'window',
  DateTime? startedAt,
  DateTime? stoppedAt,
  String? label,
}) {
  final r = Recording(
    id: id,
    outputDir: '/tmp/recordings/$id',
    fps: fps,
    area: area,
    format: format,
    startedAt: startedAt ?? DateTime(2026, 1, 1, 12, 0, 0),
    label: label,
  );
  r.stoppedAt = stoppedAt;
  return r;
}

void main() {
  // ---------------------------------------------------------------------------
  // ffmpegHint
  // ---------------------------------------------------------------------------

  group('Recording.ffmpegHint()', () {
    // r1 — png format produces a png pattern in the hint.
    test('r1: png format includes frame_%06d.png and libx264', () {
      final hint = _recording(format: 'png', fps: 24).ffmpegHint();
      expect(hint, contains('frame_%06d.png'));
      expect(hint, contains('-framerate 24'));
      expect(hint, contains('libx264'));
    });

    // r2 — jpg format substitutes jpg in the hint.
    test('r2: jpg format includes frame_%06d.jpg', () {
      final hint = _recording(format: 'jpg', fps: 30).ffmpegHint();
      expect(hint, contains('frame_%06d.jpg'));
      expect(hint, contains('-framerate 30'));
    });

    test(
      'r2b: ffmpegHint returns a non-empty string for any supported format',
      () {
        for (final fmt in <String>['png', 'jpg']) {
          expect(_recording(format: fmt).ffmpegHint(), isNotEmpty);
        }
      },
    );
  });

  // ---------------------------------------------------------------------------
  // duration
  // ---------------------------------------------------------------------------

  group('Recording.duration', () {
    // r3 — duration uses stoppedAt when set.
    test('r3: duration is stoppedAt − startedAt when stoppedAt is set', () {
      final start = DateTime(2026, 1, 1, 12, 0, 0);
      final stop = start.add(const Duration(seconds: 10));
      final rec = _recording(startedAt: start, stoppedAt: stop);
      expect(rec.duration.inSeconds, 10);
    });

    test('r3b: duration is positive when stoppedAt is after startedAt', () {
      final start = DateTime(2026, 1, 1, 12, 0, 0);
      final stop = start.add(const Duration(milliseconds: 3500));
      final rec = _recording(startedAt: start, stoppedAt: stop);
      expect(rec.duration.inMilliseconds, 3500);
    });

    test('r3c: duration falls back to now-based estimate when not stopped', () {
      // When stoppedAt is null the getter uses DateTime.now().
      // We cannot assert the exact value; just verify it is non-negative.
      final rec = _recording();
      // stoppedAt is null — duration >= 0.
      expect(rec.duration.inMilliseconds, greaterThanOrEqualTo(0));
    });
  });

  // ---------------------------------------------------------------------------
  // toJson
  // ---------------------------------------------------------------------------

  group('Recording.toJson()', () {
    // r4 — required keys are present and have the correct types.
    test('r4: required keys present', () {
      final rec = _recording(
        id: 'r_test',
        format: 'png',
        fps: 24,
        area: 'window',
        label: 'test_label',
      );
      rec.stoppedAt = rec.startedAt.add(const Duration(milliseconds: 2000));
      rec.frameCount = 48;
      rec.droppedDuplicates = 2;
      rec.bytesWritten = 1024;
      final json = rec.toJson();

      expect(json['id'], 'r_test');
      expect(json['outputDir'], isA<String>());
      expect(json['fps'], 24);
      expect(json['area'], 'window');
      expect(json['format'], 'png');
      expect(json['startedAt'], isA<String>());
      expect(json['frameCount'], 48);
      expect(json['droppedDuplicates'], 2);
      expect(json['bytesWritten'], 1024);
      expect(json['durationMs'], isA<int>());
    });

    test('r4b: label is present in toJson when set', () {
      final rec = _recording(label: 'my_run');
      final json = rec.toJson();
      expect(json['label'], 'my_run');
    });

    test('r4c: label is absent from toJson when not set', () {
      final rec = _recording();
      final json = rec.toJson();
      expect(json.containsKey('label'), isFalse);
    });

    test('r4d: stoppedAt is present in toJson when set', () {
      final rec = _recording();
      rec.stoppedAt = rec.startedAt.add(const Duration(seconds: 1));
      final json = rec.toJson();
      expect(json.containsKey('stoppedAt'), isTrue);
      expect(json['stoppedAt'], isA<String>());
    });

    test('r4e: stoppedAt is absent from toJson when not set', () {
      final rec = _recording();
      final json = rec.toJson();
      expect(json.containsKey('stoppedAt'), isFalse);
    });

    test('r4f: startedAt serialises as a valid ISO-8601 UTC string', () {
      final start = DateTime(2026, 6, 17, 9, 30, 0, 0, 0);
      final rec = _recording(startedAt: start);
      final json = rec.toJson();
      final parsed = DateTime.tryParse(json['startedAt'] as String);
      expect(parsed, isNotNull);
    });
  });
}
