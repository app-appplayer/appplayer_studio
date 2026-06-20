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
