/// Runs every video command the studio issues against the FFmpeg build it
/// actually links (the LGPL `ffmpeg_kit_flutter_new_full`), on the desktop
/// this runs on: the recorder encode (silent and with audio), trim, concat,
/// click zoom and the four web exports. Command strings are covered by unit
/// tests; only this shows the encoders and options exist in the shipped
/// build.
///
///   flutter test integration_test/video_encoders_test.dart -d macos
library;

import 'dart:io';

import 'package:appplayer_studio/src/base/capture/recorder/encoder_service.dart';
import 'package:appplayer_studio/src/base/capture/recorder/h264_encoder.dart';
import 'package:appplayer_studio/src/base/capture/recorder/recorder_models.dart';
import 'package:appplayer_studio/src/base/capture/recorder/video_edit_service.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  late String frames;
  late String tone;

  Future<void> ffmpeg(String cmd) async {
    final session = await FFmpegKit.execute(cmd);
    final code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      fail('ffmpeg failed: $cmd\n${await session.getAllLogsAsString()}');
    }
  }

  Future<String?> videoCodec(String path) async {
    final info =
        (await FFprobeKit.getMediaInformation(path)).getMediaInformation();
    for (final s in info?.getStreams() ?? const []) {
      if (s.getType() == 'video') return s.getCodec();
    }
    return null;
  }

  Future<Map<dynamic, dynamic>> videoProps(String path) async {
    final info =
        (await FFprobeKit.getMediaInformation(path)).getMediaInformation();
    return info!
            .getStreams()
            .firstWhere((s) => s.getType() == 'video')
            .getAllProperties() ??
        const <dynamic, dynamic>{};
  }

  Future<bool> hasAudio(String path) async {
    final info =
        (await FFprobeKit.getMediaInformation(path)).getMediaInformation();
    return (info?.getStreams() ?? const []).any((s) => s.getType() == 'audio');
  }

  Recording recording() => Recording(
    id: 'rec',
    outputDir: frames,
    fps: 24,
    area: 'window',
    format: 'png',
    startedAt: DateTime.now(),
  );

  setUpAll(() async {
    work = Directory.systemTemp.createTempSync('studio_video_');
    frames = p.join(work.path, 'frames');
    Directory(frames).createSync();
    // A busy test pattern, so quality settings move the output size.
    await ffmpeg(
      '-y -f lavfi -i testsrc2=size=641x361:rate=24 -t 2 '
      '"${p.join(frames, 'frame_%06d.png')}"',
    );
    tone = p.join(work.path, 'tone.m4a');
    await ffmpeg(
      '-y -f lavfi -i sine=frequency=440:duration=2 -c:a aac "$tone"',
    );
  });

  tearDownAll(() => work.deleteSync(recursive: true));

  for (final encoder in <String>{h264EncoderFor(), kOpenH264}) {
    testWidgets('recorder encode with $encoder → H.264, quality moves size', (
      tester,
    ) async {
      final sizes = <int, int>{};
      for (final crf in <int>[18, 35]) {
        final out = p.join(work.path, 'enc_${encoder}_$crf.mp4');
        final r = await EncoderService().encode(
          recording(),
          outputPath: out,
          codec: encoder,
          crf: crf,
        );
        expect(r!.status, 'done', reason: r.error);
        expect(await videoCodec(out), 'h264');
        // RGB frames converted with a named matrix and tagged with it.
        expect((await videoProps(out))['color_space'], 'bt709');
        sizes[crf] = File(out).lengthSync();
      }
      expect(sizes[18]!, greaterThan(sizes[35]!), reason: '$sizes');
    });
  }

  testWidgets('recorder encode muxes an audio track', (tester) async {
    final out = p.join(work.path, 'enc_audio.mp4');
    final r = await EncoderService().encode(
      recording(),
      outputPath: out,
      audioTracks: <Map<String, dynamic>>[
        <String, dynamic>{'path': tone, 'volume': 0.5},
      ],
    );
    expect(r!.status, 'done', reason: r.error);
    expect(await videoCodec(out), 'h264');
    expect(await hasAudio(out), isTrue);
  });

  testWidgets('recorder encode from the frame manifest keeps the real span', (
    tester,
  ) async {
    // What the recorder writes: deduped frames held for their on-screen time.
    final dir = Directory(p.join(work.path, 'held'))..createSync();
    final names = <String>[];
    for (final i in <int>[1, 2, 3]) {
      final name = 'frame_${i.toString().padLeft(6, '0')}.png';
      File(p.join(frames, name)).copySync(p.join(dir.path, name));
      names.add(name);
    }
    final manifest = buildConcatManifest(
      filenames: names,
      offsetsMs: const <int>[0, 400, 2600],
      totalDurationMs: 3000,
    );
    File(p.join(dir.path, 'frames.txt')).writeAsStringSync(manifest);
    final out = p.join(work.path, 'held.mp4');
    final r = await EncoderService().encode(
      Recording(
        id: 'held',
        outputDir: dir.path,
        fps: 24,
        area: 'window',
        format: 'png',
        startedAt: DateTime.now(),
      ),
      outputPath: out,
    );
    expect(r!.status, 'done', reason: r.error);
    final info =
        (await FFprobeKit.getMediaInformation(out)).getMediaInformation();
    expect(double.parse(info!.getDuration()!), closeTo(3.0, 0.1));
  });

  testWidgets('trim · concat · zoom · web exports', (tester) async {
    final edit = VideoEditService();
    final src = p.join(work.path, 'src.mp4');
    expect(
      (await EncoderService().encode(recording(), outputPath: src))!.status,
      'done',
    );

    final trimmed = p.join(work.path, 'trim.mp4');
    final trim = await edit.trim(
      input: src,
      startSec: 0.5,
      endSec: 1.5,
      output: trimmed,
    );
    expect(trim.ok, isTrue, reason: trim.error);
    expect(await videoCodec(trimmed), 'h264');

    final joined = p.join(work.path, 'concat.mp4');
    final concat = await edit.concat(
      inputs: <String>[trimmed, trimmed],
      output: joined,
      workDir: work.path,
    );
    expect(concat.ok, isTrue, reason: concat.error);

    final size = await edit.probeSize(src);
    expect(size, isNotNull);
    final zoomed = p.join(work.path, 'zoom.mp4');
    final zoom = await edit.zoom(
      input: src,
      output: zoomed,
      width: size!.$1,
      height: size.$2,
      startSec: 0.2,
      endSec: 1.8,
    );
    expect(zoom.ok, isTrue, reason: zoom.error);
    expect(await videoCodec(zoomed), 'h264');

    const expected = <String, String>{
      'mp4': 'h264',
      'webm': 'vp9',
      'gif': 'gif',
      'webp': 'webp',
    };
    for (final e in expected.entries) {
      final out = p.join(work.path, 'export.${e.key}');
      final r = await edit.convert(input: trimmed, output: out, format: e.key);
      expect(r.ok, isTrue, reason: '${e.key}: ${r.error}');
      expect(await videoCodec(out), e.value, reason: e.key);
    }
    // The web export must be decodable by browsers: VP9 profile 0 in YUV,
    // never tagged RGB (the trimmed clip carries the recording's tags).
    final webm = await videoProps(p.join(work.path, 'export.webm'));
    expect(webm['pix_fmt'], 'yuv420p');
    expect(webm['color_space'], 'bt709');
  });
}
