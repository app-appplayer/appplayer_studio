/// Models for the recorder service.
library;

import 'h264_encoder.dart';

/// Active or completed recording session.
class Recording {
  Recording({
    required this.id,
    required this.outputDir,
    required this.fps,
    required this.area,
    required this.format,
    required this.startedAt,
    this.label,
  });

  final String id;
  final String outputDir;
  final int fps;
  final String area; // 'window' | 'body' | 'left_panel' | 'rect:x,y,w,h'
  final String format; // 'png' | 'jpg'
  final DateTime startedAt;
  final String? label;

  DateTime? stoppedAt;
  int frameCount = 0;
  int droppedDuplicates = 0;
  int bytesWritten = 0;

  /// Elapsed milliseconds from [startedAt] at which each WRITTEN frame was
  /// captured — one entry per unique (post-dedup) frame, parallel to the
  /// `frame_NNNNNN` files. The gap to the next entry is how long that frame
  /// stayed on screen; this drives the encoder's concat manifest so a static
  /// scene keeps its real span instead of collapsing to frameCount / fps (D3).
  final List<int> frameOffsetsMs = <int>[];

  Duration get duration => (stoppedAt ?? DateTime.now()).difference(startedAt);

  /// Copy-pastable ffmpeg command that encodes the frame sequence into an
  /// mp4 outside the app, with the same H.264 encoder and quality the
  /// in-app encoder uses on this machine.
  String ffmpegHint() {
    final ext = format == 'jpg' ? 'jpg' : 'png';
    return 'ffmpeg -framerate $fps -i frame_%06d.$ext '
        '${h264VideoArgs()} $kBt709Tags '
        '-vf "pad=ceil(iw/2)*2:ceil(ih/2)*2,$kRgbToBt709Filter" out.mp4';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    if (label != null) 'label': label,
    'outputDir': outputDir,
    'fps': fps,
    'area': area,
    'format': format,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (stoppedAt != null) 'stoppedAt': stoppedAt!.toUtc().toIso8601String(),
    'durationMs': duration.inMilliseconds,
    'frameCount': frameCount,
    'droppedDuplicates': droppedDuplicates,
    'bytesWritten': bytesWritten,
  };
}

/// Build an ffmpeg **concat demuxer** manifest that holds each deduped frame
/// for its real on-screen span, so a static scene keeps its true duration
/// instead of collapsing to unique-frame-count / fps (D3).
///
/// [filenames] are the surviving frame files (basenames, resolved relative to
/// the manifest's own directory); [offsetsMs] is each frame's capture time
/// from record start (parallel to [filenames]); [totalDurationMs] is the full
/// record span (stop − start), used for the final frame's hold. The concat
/// demuxer IGNORES the last entry's `duration`, so the final frame is repeated
/// to make its span count. Pure (no I/O) — unit-testable.
String buildConcatManifest({
  required List<String> filenames,
  required List<int> offsetsMs,
  required int totalDurationMs,
}) {
  final b = StringBuffer('ffconcat version 1.0\n');
  for (var i = 0; i < filenames.length; i++) {
    final startMs = offsetsMs[i];
    final endMs = i + 1 < filenames.length ? offsetsMs[i + 1] : totalDurationMs;
    final durMs = (endMs - startMs).clamp(1, 1 << 30);
    b.writeln("file '${filenames[i]}'");
    b.writeln('duration ${(durMs / 1000).toStringAsFixed(3)}');
  }
  if (filenames.isNotEmpty) {
    // Repeat the final frame so even a single static frame is held: the concat
    // demuxer ignores the LAST entry's `duration` and holds that frame for the
    // PREVIOUS duration, so the repeat absorbs the ignored slot. The resulting
    // stream over-runs the real span, so the encoder trims it with `-t`
    // (see [sumConcatManifestSeconds] / buildEncodeCommand).
    b.writeln("file '${filenames.last}'");
  }
  return b.toString();
}

/// Sum of the `duration` directives in a concat [manifest] (seconds) — the
/// real recording span, used to pin the encode length with ffmpeg `-t`. The
/// repeated final frame carries no `duration` line, so it is not counted.
/// Pure — unit-testable.
double sumConcatManifestSeconds(String manifest) {
  var total = 0.0;
  for (final line in manifest.split('\n')) {
    final t = line.trim();
    if (t.startsWith('duration ')) {
      total += double.tryParse(t.substring('duration '.length).trim()) ?? 0.0;
    }
  }
  return total;
}
