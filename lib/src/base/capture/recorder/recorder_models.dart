/// Models for the recorder service.
library;

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

  /// Suggested ffmpeg command authors run post-hoc to encode the PNG
  /// sequence into an mp4. Phase 2 will replace this with an in-app
  /// encoder; Phase 1 ships a copy-pastable hint so the user isn't
  /// stuck if ffmpeg is on their PATH.
  String ffmpegHint() {
    final ext = format == 'jpg' ? 'jpg' : 'png';
    return 'ffmpeg -framerate $fps -i frame_%06d.$ext '
        '-c:v libx264 -pix_fmt yuv420p '
        '-vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" out.mp4';
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
    // Repeat the final frame — the concat demuxer drops the last duration.
    b.writeln("file '${filenames.last}'");
  }
  return b.toString();
}
