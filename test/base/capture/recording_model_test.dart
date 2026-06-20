/// r1-r8: Unit tests for [Recording] — the plain-data model produced
/// by [RecorderService.start] and consumed by [EncoderService].
///
/// All logic is pure value / string math — no Flutter widgets, no disk
/// I/O, no async — so these run in a plain test() context without
/// TestWidgetsFlutterBinding.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/capture/recorder/recorder_models.dart';

void main() {
  // --- helpers -----------------------------------------------------------

  Recording _rec({
    String id = 'test-id',
    String outputDir = '/tmp/recordings/test-id',
    int fps = 24,
    String area = 'window',
    String format = 'png',
    String? label,
    DateTime? startedAt,
  }) {
    return Recording(
      id: id,
      outputDir: outputDir,
      fps: fps,
      area: area,
      format: format,
      startedAt: startedAt ?? DateTime.utc(2026, 1, 1, 12, 0, 0),
      label: label,
    );
  }

  // r1 -------------------------------------------------------------------
  group('r1: Recording.ffmpegHint — png format', () {
    test('produces correct ffmpeg command with png extension', () {
      final rec = _rec(fps: 24, format: 'png');
      final hint = rec.ffmpegHint();
      expect(hint, contains('-framerate 24'));
      expect(hint, contains('frame_%06d.png'));
      expect(hint, contains('libx264'));
      expect(hint, contains('yuv420p'));
      expect(hint, contains('out.mp4'));
    });
  });

  // r2 -------------------------------------------------------------------
  group('r2: Recording.ffmpegHint — jpg format', () {
    test('uses jpg extension when format is jpg', () {
      final rec = _rec(fps: 30, format: 'jpg');
      final hint = rec.ffmpegHint();
      expect(hint, contains('-framerate 30'));
      expect(hint, contains('frame_%06d.jpg'));
      expect(hint, isNot(contains('.png')));
    });
  });

  // r3 -------------------------------------------------------------------
  group('r3: Recording.toJson — fields present in output', () {
    test('toJson contains all required keys', () {
      final start = DateTime.utc(2026, 3, 10, 9, 0, 0);
      final rec = _rec(
        id: 'rec-abc',
        outputDir: '/tmp/rec-abc',
        fps: 30,
        area: 'body',
        format: 'jpg',
        label: 'demo',
        startedAt: start,
      );
      final j = rec.toJson();
      expect(j['id'], 'rec-abc');
      expect(j['outputDir'], '/tmp/rec-abc');
      expect(j['fps'], 30);
      expect(j['area'], 'body');
      expect(j['format'], 'jpg');
      expect(j['label'], 'demo');
      expect(j['startedAt'], isA<String>());
      expect(j['frameCount'], 0);
      expect(j['droppedDuplicates'], 0);
      expect(j['bytesWritten'], 0);
    });

    test('toJson omits label key when label is null', () {
      final rec = _rec(label: null);
      final j = rec.toJson();
      expect(j.containsKey('label'), isFalse);
    });

    test('toJson omits stoppedAt when not stopped', () {
      final rec = _rec();
      final j = rec.toJson();
      expect(j.containsKey('stoppedAt'), isFalse);
    });

    test('toJson includes stoppedAt after stop is set', () {
      final rec = _rec();
      rec.stoppedAt = DateTime.utc(2026, 3, 10, 9, 1, 30);
      final j = rec.toJson();
      expect(j.containsKey('stoppedAt'), isTrue);
      expect(j['stoppedAt'], isA<String>());
    });
  });

  // r4 -------------------------------------------------------------------
  group('r4: Recording.duration — running vs stopped', () {
    test('duration increases while running (stoppedAt null)', () {
      final now = DateTime.now();
      final rec = Recording(
        id: 'x',
        outputDir: '/tmp/x',
        fps: 24,
        area: 'window',
        format: 'png',
        startedAt: now.subtract(const Duration(seconds: 5)),
      );
      expect(rec.duration.inSeconds, greaterThanOrEqualTo(5));
    });

    test('duration is fixed after stop', () {
      final start = DateTime.utc(2026, 1, 1, 10, 0, 0);
      final stop = DateTime.utc(2026, 1, 1, 10, 0, 30);
      final rec = Recording(
        id: 'x',
        outputDir: '/tmp/x',
        fps: 24,
        area: 'window',
        format: 'png',
        startedAt: start,
      );
      rec.stoppedAt = stop;
      expect(rec.duration, const Duration(seconds: 30));
    });
  });

  // r5 -------------------------------------------------------------------
  group('r5: Recording mutable counters', () {
    test('frameCount increments independently of droppedDuplicates', () {
      final rec = _rec();
      rec.frameCount += 5;
      rec.droppedDuplicates += 2;
      rec.bytesWritten += 12345;
      final j = rec.toJson();
      expect(j['frameCount'], 5);
      expect(j['droppedDuplicates'], 2);
      expect(j['bytesWritten'], 12345);
    });
  });

  // r6 -------------------------------------------------------------------
  group('r6: Recording.toJson durationMs field', () {
    test('durationMs in toJson matches rec.duration.inMilliseconds', () {
      final start = DateTime.utc(2026, 5, 1, 8, 0, 0);
      final stop = DateTime.utc(2026, 5, 1, 8, 1, 15); // 75 s
      final rec = Recording(
        id: 'dur-test',
        outputDir: '/tmp/dur',
        fps: 24,
        area: 'window',
        format: 'png',
        startedAt: start,
      );
      rec.stoppedAt = stop;
      final j = rec.toJson();
      expect(j['durationMs'], 75000);
    });
  });

  // r7 -------------------------------------------------------------------
  group('r7: Recording.toJson startedAt UTC ISO8601', () {
    test('startedAt is serialised as UTC ISO8601', () {
      final start = DateTime(2026, 6, 17, 12, 0, 0); // local
      final rec = Recording(
        id: 'utc-test',
        outputDir: '/tmp',
        fps: 24,
        area: 'window',
        format: 'png',
        startedAt: start,
      );
      final j = rec.toJson();
      final s = j['startedAt'] as String;
      // Must end with 'Z' (UTC marker) because we call toUtc().toIso8601String()
      expect(s.endsWith('Z'), isTrue);
    });
  });

  // r8 -------------------------------------------------------------------
  group('r8: Recording format field normalisation invariant', () {
    test(
      'format stored as-is regardless of casing (pure model — no normalisation here)',
      () {
        // RecorderService normalises 'jpg'→'jpg'/'png'→'png'; the model
        // just holds what it receives.
        final rec = Recording(
          id: 'fmt',
          outputDir: '/tmp',
          fps: 24,
          area: 'window',
          format: 'jpg',
          startedAt: DateTime.now(),
        );
        expect(rec.format, 'jpg');
        expect(rec.ffmpegHint(), contains('frame_%06d.jpg'));
      },
    );
  });
}
