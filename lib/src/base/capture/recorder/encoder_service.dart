/// In-app encoder — wraps `ffmpeg_kit_flutter_new` to turn a PNG
/// sequence (the recorder's output) into an MP4. Runs async via
/// `FFmpegKit.executeAsync` so the UI thread stays free; the studio's
/// core tool work is never delayed by encoding progress (the
/// recorder's hard constraint per the capture/ module's design).
///
/// Single-encode-at-a-time semantics — the encoder refuses a second
/// `encode()` while one is in flight. Outputs land next to the source
/// directory as `<recording-id>.mp4`. Progress is reported back to
/// callers through a `ValueNotifier<EncodingProgress?>`.
library;

import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'recorder_models.dart';

class EncodingProgress {
  EncodingProgress({
    required this.recordingId,
    required this.outputPath,
    required this.startedAt,
    this.completedAt,
    this.status = 'running',
    this.error,
    this.outputBytes,
  });
  final String recordingId;
  final String outputPath;
  final DateTime startedAt;
  DateTime? completedAt;

  /// running | done | failed
  String status;
  String? error;
  int? outputBytes;

  Duration get elapsed => (completedAt ?? DateTime.now()).difference(startedAt);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'recordingId': recordingId,
    'outputPath': outputPath,
    'status': status,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (completedAt != null)
      'completedAt': completedAt!.toUtc().toIso8601String(),
    'elapsedMs': elapsed.inMilliseconds,
    if (error != null) 'error': error,
    if (outputBytes != null) 'outputBytes': outputBytes,
  };
}

/// Builds the ffmpeg command line for an encode. Pure (no I/O) so it can
/// be unit-tested without invoking ffmpeg.
///
/// With no [audioTracks] this is the proven video-only path (simple `-vf`
/// pad). With one or more tracks the pad moves into a `filter_complex`
/// graph (so it shares the graph with the audio mix); each track is
/// delayed (`adelay`) and leveled (`volume`), then `amix`ed down into a
/// single AAC stream muxed alongside the video.
///
/// Each audio track map: `{path, startMs?, volume?}` — `startMs` offsets
/// the clip on the timeline (narration that starts a few seconds in),
/// `volume` scales gain (1.0 = unchanged; ~0.2 for background music sat
/// under a voiceover). `-shortest` trims output to the shorter of video /
/// audio so a slightly-long narration can't leave a black tail.
String buildEncodeCommand({
  required String pattern,
  required int fps,
  required String out,
  String codec = 'libx264',
  String pixelFormat = 'yuv420p',
  int? crf,
  List<Map<String, dynamic>> audioTracks = const <Map<String, dynamic>>[],
}) {
  final crfArg = crf == null ? '' : '-crf $crf ';
  const pad = 'pad=ceil(iw/2)*2:ceil(ih/2)*2';
  final tracks = audioTracks
      .where((t) => (t['path']?.toString() ?? '').isNotEmpty)
      .toList(growable: false);
  if (tracks.isEmpty) {
    // Unchanged simple-filter path — keep the proven behavior.
    return '-y -framerate $fps -i "$pattern" -c:v $codec '
        '-pix_fmt $pixelFormat $crfArg-vf "$pad" "$out"';
  }
  final inputs = StringBuffer('-y -framerate $fps -i "$pattern"');
  for (final t in tracks) {
    inputs.write(' -i "${t['path']}"');
  }
  final graph = StringBuffer('[0:v]$pad[v]');
  final labels = <String>[];
  for (var i = 0; i < tracks.length; i++) {
    final t = tracks[i];
    final startMs = t['startMs'] is num ? (t['startMs'] as num).round() : 0;
    final volume = t['volume'] is num ? (t['volume'] as num).toDouble() : 1.0;
    final inIdx = i + 1; // input 0 is the PNG sequence
    graph.write(';[$inIdx:a]adelay=$startMs:all=1,volume=$volume[a$i]');
    labels.add('a$i');
  }
  final String audioOut;
  if (labels.length == 1) {
    audioOut = labels.first;
  } else {
    final ins = labels.map((l) => '[$l]').join();
    graph.write(
      ';${ins}amix=inputs=${labels.length}:dropout_transition=0:normalize=0[aout]',
    );
    audioOut = 'aout';
  }
  return '$inputs -filter_complex "$graph" -map "[v]" -map "[$audioOut]" '
      '-c:v $codec -pix_fmt $pixelFormat $crfArg-c:a aac -shortest "$out"';
}

class EncoderService {
  EncoderService();

  final ValueNotifier<EncodingProgress?> progress =
      ValueNotifier<EncodingProgress?>(null);
  bool _busy = false;
  bool get busy => _busy;

  /// Encode [rec]'s PNG sequence into an MP4 at `<outputDir>/<id>.mp4`.
  /// Returns a Future that resolves to the final [EncodingProgress]
  /// once ffmpeg exits — UI thread isn't blocked because FFmpegKit's
  /// session runs on a native worker.
  ///
  /// Returns null when an encode is already in flight.
  Future<EncodingProgress?> encode(
    Recording rec, {
    String? outputPath,
    String codec = 'libx264',
    String pixelFormat = 'yuv420p',
    int? crf,
    List<Map<String, dynamic>> audioTracks = const <Map<String, dynamic>>[],
  }) async {
    if (_busy) return null;
    _busy = true;
    final out = outputPath ?? p.join(rec.outputDir, '${rec.id}.mp4');
    final prog = EncodingProgress(
      recordingId: rec.id,
      outputPath: out,
      startedAt: DateTime.now(),
    );
    progress.value = prog;
    final completer = Completer<EncodingProgress>();
    final pattern = p.join(rec.outputDir, 'frame_%06d.${rec.format}');
    // `pad=ceil(iw/2)*2:ceil(ih/2)*2` (inside the builder) ensures even
    // dimensions — libx264 + yuv420p require it. Overwrites output;
    // muxes any `audioTracks` (narration / music) into an AAC stream.
    final cmd = buildEncodeCommand(
      pattern: pattern,
      fps: rec.fps,
      out: out,
      codec: codec,
      pixelFormat: pixelFormat,
      crf: crf,
      audioTracks: audioTracks,
    );
    try {
      await FFmpegKit.executeAsync(cmd, (session) async {
        final code = await session.getReturnCode();
        prog.completedAt = DateTime.now();
        if (ReturnCode.isSuccess(code)) {
          prog.status = 'done';
          try {
            final f = File(out);
            if (await f.exists()) prog.outputBytes = await f.length();
          } catch (_) {
            /* swallow */
          }
        } else {
          prog.status = 'failed';
          final logs = await session.getAllLogsAsString();
          prog.error = (logs ?? 'unknown ffmpeg failure').trim();
        }
        progress.value = prog;
        _busy = false;
        if (!completer.isCompleted) completer.complete(prog);
      });
    } catch (e) {
      prog.completedAt = DateTime.now();
      prog.status = 'failed';
      prog.error = e.toString();
      progress.value = prog;
      _busy = false;
      if (!completer.isCompleted) completer.complete(prog);
    }
    return completer.future;
  }

  /// Cancel the active session (best-effort). FFmpegKit will mark the
  /// session cancelled and the executeAsync callback resolves with a
  /// non-success return code.
  Future<void> cancel() async {
    if (!_busy) return;
    await FFmpegKit.cancel();
  }
}
