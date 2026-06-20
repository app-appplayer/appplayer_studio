/// In-app video editing primitives — trim & concat of EXISTING video
/// files (imported clips or prior recordings), on top of
/// `ffmpeg_kit_flutter_new`. This is the editing LOGIC (host primitive);
/// the Scene Builder builtin only wires to it through `studio.video.*`
/// MCP tools (builtin = UI + wiring, no logic).
///
/// Distinct from `EncoderService` (PNG sequence → mp4). Here the inputs
/// are already video files.
library;

import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;

/// Result of a trim / concat op.
class VideoEditResult {
  VideoEditResult({
    required this.ok,
    required this.outputPath,
    this.error,
    this.outputBytes,
  });
  final bool ok;
  final String outputPath;
  final String? error;
  final int? outputBytes;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ok': ok,
    'outputPath': outputPath,
    if (error != null) 'error': error,
    if (outputBytes != null) 'outputBytes': outputBytes,
  };
}

/// Pure — ffmpeg trim command. Re-encodes with output-side `-ss`/`-to`
/// for **frame-accurate** cuts (stream-copy is keyframe-bound). Keeps
/// [startSec]..[endSec] (endSec null = to clip end). `-c:a aac` is a
/// no-op when the source has no audio track.
String buildTrimCommand({
  required String input,
  required double startSec,
  double? endSec,
  required String output,
  String codec = 'libx264',
  String pixelFormat = 'yuv420p',
  int? crf,
}) {
  final crfArg = crf == null ? '' : '-crf $crf ';
  final to = endSec == null ? '' : '-to ${endSec.toStringAsFixed(3)} ';
  return '-y -i "$input" -ss ${startSec.toStringAsFixed(3)} $to'
      '-c:v $codec -pix_fmt $pixelFormat $crfArg-c:a aac "$output"';
}

/// Pure — the concat-demuxer list-file body for [inputs] (absolute paths,
/// in order). One `file '<path>'` per line; single quotes escaped per
/// ffmpeg's rule.
String buildConcatListFile(List<String> inputs) =>
    inputs.map((path) => "file '${path.replaceAll("'", "'\\''")}'").join('\n');

/// Pure — ffmpeg concat (demuxer) command. [listPath] is a file written
/// from [buildConcatListFile]. Stream-copy — clips must share
/// codec/resolution/fps (true for studio recordings and clips trimmed to
/// the canonical libx264/yuv420p above; mixed-spec imports need a
/// normalize pass first).
String buildConcatCommand({required String listPath, required String output}) =>
    '-y -f concat -safe 0 -i "$listPath" -c copy "$output"';

/// Pure — ffmpeg command to convert [input] video to a web-friendly
/// [format] (`webm` · `gif` · `webp` · `mp4`). Homepage demos prefer
/// autoplay-loop `webm`(VP9) or animated `webp`/`gif` over raw mp4.
/// [fps] (gif/webp default 15/20) and [width] (scale, -1 = keep ratio)
/// trim weight. gif/webp drop audio.
String buildConvertCommand({
  required String input,
  required String output,
  required String format,
  int? fps,
  int? width,
  int? crf,
}) {
  final scale = width == null ? '' : ',scale=$width:-1:flags=lanczos';
  switch (format) {
    case 'webm':
      // VP9 + Opus. crf with -b:v 0 = constant-quality.
      final q = crf == null ? '' : '-crf $crf -b:v 0 ';
      return '-y -i "$input" -c:v libvpx-vp9 $q-c:a libopus "$output"';
    case 'gif':
      // Palette pass (palettegen/paletteuse) for clean colors.
      final f = fps ?? 15;
      return '-y -i "$input" -filter_complex '
          '"fps=$f$scale,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" '
          '"$output"';
    case 'webp':
      // Animated WebP — lighter than gif, looped.
      final f = fps ?? 20;
      return '-y -i "$input" -vf "fps=$f$scale" '
          '-c:v libwebp -loop 0 -q:v 70 "$output"';
    case 'mp4':
    default:
      final q = crf == null ? '' : '-crf $crf ';
      return '-y -i "$input" -c:v libx264 -pix_fmt yuv420p $q-c:a aac '
          '"$output"';
  }
}

/// Pure — ffmpeg trapezoidal zoom expression z(t): 1 before [startSec],
/// eased ramp up to [zoom] over [rampSec], hold, ramp back to 1 by
/// [endSec]. Emitted as an ffmpeg `crop` time-expression (uses `t`).
String buildZoomExpr({
  required double startSec,
  required double endSec,
  required double zoom,
  required double rampSec,
}) {
  final s = startSec.toStringAsFixed(3);
  final e = endSec.toStringAsFixed(3);
  final z = zoom.toStringAsFixed(4);
  final up = (startSec + rampSec).toStringAsFixed(3);
  final down = (endSec - rampSec).toStringAsFixed(3);
  final r = rampSec.toStringAsFixed(3);
  // Nested if(): before start → 1; ramp up → 1+(z-1)*(t-s)/r; hold → z;
  // ramp down → z-(z-1)*(t-down)/r; after end → 1.
  return 'if(lt(t,$s),1,'
      'if(lt(t,$up),1+($z-1)*(t-$s)/$r,'
      'if(lt(t,$down),$z,'
      'if(lt(t,$e),$z-($z-1)*(t-$down)/$r,1))))';
}

/// Pure — ffmpeg command for a Screen-Studio-style click zoom: smoothly
/// zooms the [width]x[height] frame toward the normalized focus point
/// ([focusX], [focusY] in 0..1) between [startSec] and [endSec], then
/// back out. Implemented as a time-varying `crop` (window shrinks toward
/// the point) followed by `scale` back to full size.
String buildZoomCommand({
  required String input,
  required String output,
  required int width,
  required int height,
  required double startSec,
  required double endSec,
  double zoom = 1.6,
  double focusX = 0.5,
  double focusY = 0.5,
  double rampSec = 0.4,
}) {
  final z = buildZoomExpr(
    startSec: startSec,
    endSec: endSec,
    zoom: zoom,
    rampSec: rampSec,
  );
  final nx = focusX.clamp(0.0, 1.0).toStringAsFixed(4);
  final ny = focusY.clamp(0.0, 1.0).toStringAsFixed(4);
  // crop window = in_w/z × in_h/z, top-left offset so the focus point
  // stays put; even dims via floor(/2)*2; scale back to source size.
  final cw = 'floor(in_w/($z)/2)*2';
  final ch = 'floor(in_h/($z)/2)*2';
  final cx = '(in_w-$cw)*$nx';
  final cy = '(in_h-$ch)*$ny';
  final vf =
      "crop=w='$cw':h='$ch':x='$cx':y='$cy',"
      'scale=$width:$height:flags=bicubic,setsar=1';
  return '-y -i "$input" -vf "$vf" -c:v libx264 -pix_fmt yuv420p '
      '-c:a copy "$output"';
}

class VideoEditService {
  VideoEditService();

  bool _busy = false;
  bool get busy => _busy;

  /// Trim [input] to [startSec]..[endSec] → [output] (default:
  /// `<input>_trim.mp4` beside the source).
  Future<VideoEditResult> trim({
    required String input,
    required double startSec,
    double? endSec,
    String? output,
    int? crf,
  }) async {
    final out =
        output ??
        p.join(
          p.dirname(input),
          '${p.basenameWithoutExtension(input)}_trim.mp4',
        );
    return _run(
      buildTrimCommand(
        input: input,
        startSec: startSec,
        endSec: endSec,
        output: out,
        crf: crf,
      ),
      out,
    );
  }

  /// Concatenate [inputs] (in order) → [output]. Writes the demuxer list
  /// file into [workDir] (a temp dir).
  Future<VideoEditResult> concat({
    required List<String> inputs,
    required String output,
    required String workDir,
  }) async {
    if (inputs.length < 2) {
      return VideoEditResult(
        ok: false,
        outputPath: output,
        error: 'concat needs at least 2 clips',
      );
    }
    final listPath = p.join(workDir, 'concat_list.txt');
    await File(
      listPath,
    ).writeAsString(buildConcatListFile(inputs), flush: true);
    return _run(buildConcatCommand(listPath: listPath, output: output), output);
  }

  /// Convert [input] video to [format] (`webm`/`gif`/`webp`/`mp4`) → [output]
  /// — web-friendly export for homepage demos.
  Future<VideoEditResult> convert({
    required String input,
    required String output,
    required String format,
    int? fps,
    int? width,
    int? crf,
  }) => _run(
    buildConvertCommand(
      input: input,
      output: output,
      format: format,
      fps: fps,
      width: width,
      crf: crf,
    ),
    output,
  );

  /// Click zoom — zoom [input] toward ([focusX], [focusY]) (normalized)
  /// between [startSec] and [endSec], then back out → [output]. Needs the
  /// source [width]/[height] (from [probeSize]).
  Future<VideoEditResult> zoom({
    required String input,
    required String output,
    required int width,
    required int height,
    required double startSec,
    required double endSec,
    double zoom = 1.6,
    double focusX = 0.5,
    double focusY = 0.5,
    double rampSec = 0.4,
  }) => _run(
    buildZoomCommand(
      input: input,
      output: output,
      width: width,
      height: height,
      startSec: startSec,
      endSec: endSec,
      zoom: zoom,
      focusX: focusX,
      focusY: focusY,
      rampSec: rampSec,
    ),
    output,
  );

  /// Duration of [input] in seconds (null if unprobeable).
  Future<double?> probeDuration(String input) async {
    final session = await FFprobeKit.getMediaInformation(input);
    final d = session.getMediaInformation()?.getDuration();
    return d == null ? null : double.tryParse(d);
  }

  /// Pixel dimensions `(width, height)` of [input]'s first video stream
  /// (null if unprobeable).
  Future<(int, int)?> probeSize(String input) async {
    final session = await FFprobeKit.getMediaInformation(input);
    final streams = session.getMediaInformation()?.getStreams();
    if (streams == null) return null;
    for (final s in streams) {
      final w = s.getWidth();
      final h = s.getHeight();
      if (w != null && h != null && w > 0 && h > 0) {
        return (w.toInt(), h.toInt());
      }
    }
    return null;
  }

  Future<VideoEditResult> _run(String cmd, String out) async {
    if (_busy) {
      return VideoEditResult(
        ok: false,
        outputPath: out,
        error: 'video-edit busy',
      );
    }
    _busy = true;
    final completer = Completer<VideoEditResult>();
    try {
      await FFmpegKit.executeAsync(cmd, (session) async {
        final code = await session.getReturnCode();
        _busy = false;
        if (ReturnCode.isSuccess(code)) {
          int? bytes;
          try {
            final f = File(out);
            if (await f.exists()) bytes = await f.length();
          } catch (_) {
            /* swallow */
          }
          if (!completer.isCompleted) {
            completer.complete(
              VideoEditResult(ok: true, outputPath: out, outputBytes: bytes),
            );
          }
        } else {
          final logs = await session.getAllLogsAsString();
          if (!completer.isCompleted) {
            completer.complete(
              VideoEditResult(
                ok: false,
                outputPath: out,
                error: (logs ?? 'unknown ffmpeg failure').trim(),
              ),
            );
          }
        }
      });
    } catch (e) {
      _busy = false;
      if (!completer.isCompleted) {
        completer.complete(
          VideoEditResult(ok: false, outputPath: out, error: e.toString()),
        );
      }
    }
    return completer.future;
  }
}
