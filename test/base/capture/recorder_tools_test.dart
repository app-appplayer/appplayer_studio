/// r35-r46: Unit tests for [recorder_tools] MCP registration.
///
/// Drives studio.recorder.start / stop / status / mark / caption /
/// recordings.list through InProcessKernelServerHost with a real
/// RecorderService whose ChromeBridge has no captureScreenshot slot
/// (so no frames are written — only state transitions matter).
///
/// studio.recorder.encode is NOT tested here because EncoderService
/// wraps ffmpeg_kit_flutter_new which requires a native plugin — that
/// path is integration-only.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/capture/overlay/overlay_controller.dart';
import 'package:appplayer_studio/src/base/capture/recorder/encoder_service.dart';
import 'package:appplayer_studio/src/base/capture/recorder/recorder_service.dart';
import 'package:appplayer_studio/src/base/capture/recorder/recorder_tools.dart';
import 'package:appplayer_studio/src/base/capture/scene_project/scene_project_tools.dart';
import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _callResult(mk.KernelToolResult r) {
  final text = (r.content.first as mk.KernelTextContent).text;
  return jsonDecode(text) as Map<String, dynamic>;
}

/// Build a full set of recorder tools on an InProcessKernelServerHost.
/// Returns the service + boot + configRoot temp dir.
({
  mk.InProcessKernelServerHost boot,
  RecorderService recorder,
  EncoderService encoder,
  Directory tmp,
})
_setup() {
  final tmp = Directory.systemTemp.createTempSync('rec_tools_test_');
  final bridge = ChromeBridge(); // captureScreenshot = null
  final recorder = RecorderService(bridge: bridge, configRoot: tmp.path);
  final encoder = EncoderService();
  final boot = mk.InProcessKernelServerHost();
  registerRecorderTools(boot, recorder: recorder, encoder: encoder);
  return (boot: boot, recorder: recorder, encoder: encoder, tmp: tmp);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SceneProjectScope.activePath = null;
  });

  tearDown(() {
    SceneProjectScope.activePath = null;
  });

  // r35 ------------------------------------------------------------------
  group('r35: tool registration', () {
    test('all studio.recorder.* tools are registered', () {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() async {
        await recorder.stop();
        tmp.deleteSync(recursive: true);
      });

      final names = boot.toolDefinitions.map((t) => t.name).toSet();
      for (final expected in <String>[
        'studio.recorder.start',
        'studio.recorder.stop',
        'studio.recorder.encode',
        'studio.recorder.recordings.list',
        'studio.recorder.status',
        'studio.recorder.mark',
        'studio.recorder.caption',
      ]) {
        expect(
          names.contains(expected),
          isTrue,
          reason: 'expected $expected to be registered',
        );
      }
    });
  });

  // r36 ------------------------------------------------------------------
  group('r36: studio.recorder.start — happy path', () {
    test('returns ok:true with recordingId, outputDir, fps, format', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() async {
        await recorder.stop();
        tmp.deleteSync(recursive: true);
      });

      final result = await boot.callTool(
        'studio.recorder.start',
        <String, dynamic>{'fps': 12, 'format': 'png', 'label': 'test-label'},
      );
      final j = _callResult(result);
      expect(j['ok'], isTrue);
      expect(j['recordingId'], isA<String>());
      expect(j['outputDir'], isA<String>());
      expect(j['fps'], 12);
      expect(j['format'], 'png');
      expect(recorder.active, isNotNull);
    });
  });

  // r37 ------------------------------------------------------------------
  group('r37: studio.recorder.start — already-recording guard', () {
    test(
      'second start returns ok:false with reason:already-recording',
      () async {
        final (:boot, :recorder, :encoder, :tmp) = _setup();
        addTearDown(() async {
          await recorder.stop();
          tmp.deleteSync(recursive: true);
        });

        await boot.callTool('studio.recorder.start', <String, dynamic>{});
        expect(recorder.active, isNotNull);

        final result = await boot.callTool(
          'studio.recorder.start',
          <String, dynamic>{},
        );
        final j = _callResult(result);
        expect(j['ok'], isFalse);
        expect(j['reason'], 'already-recording');
        expect(j['activeId'], isA<String>());
      },
    );
  });

  // r38 ------------------------------------------------------------------
  group('r38: studio.recorder.stop — happy path', () {
    test(
      'stop after start returns ok:true with frameCount and ffmpegHint',
      () async {
        final (:boot, :recorder, :encoder, :tmp) = _setup();
        addTearDown(() => tmp.deleteSync(recursive: true));

        await boot.callTool('studio.recorder.start', <String, dynamic>{});
        final result = await boot.callTool(
          'studio.recorder.stop',
          <String, dynamic>{},
        );
        final j = _callResult(result);
        expect(j['ok'], isTrue);
        expect(j.containsKey('frameCount'), isTrue);
        expect(j.containsKey('ffmpegHint'), isTrue);
        expect(j['ffmpegHint'], isA<String>());
        expect(recorder.active, isNull);
      },
    );
  });

  // r39 ------------------------------------------------------------------
  group('r39: studio.recorder.stop — not-recording guard', () {
    test(
      'stop with nothing active returns ok:false with reason:not-recording',
      () async {
        final (:boot, :recorder, :encoder, :tmp) = _setup();
        addTearDown(() => tmp.deleteSync(recursive: true));

        expect(recorder.active, isNull);
        final result = await boot.callTool(
          'studio.recorder.stop',
          <String, dynamic>{},
        );
        final j = _callResult(result);
        expect(j['ok'], isFalse);
        expect(j['reason'], 'not-recording');
      },
    );
  });

  // r40 ------------------------------------------------------------------
  group('r40: studio.recorder.status', () {
    test('returns active:false when not recording', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() => tmp.deleteSync(recursive: true));

      final result = await boot.callTool(
        'studio.recorder.status',
        <String, dynamic>{},
      );
      final j = _callResult(result);
      expect(j['active'], isFalse);
    });

    test('returns active:true with id while recording', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() async {
        await recorder.stop();
        tmp.deleteSync(recursive: true);
      });

      await boot.callTool('studio.recorder.start', <String, dynamic>{
        'label': 'status-test',
      });
      final result = await boot.callTool(
        'studio.recorder.status',
        <String, dynamic>{},
      );
      final j = _callResult(result);
      expect(j['active'], isTrue);
      expect(j['id'], isA<String>());
      expect(j.containsKey('markers'), isTrue);
      expect(j.containsKey('captions'), isTrue);
    });
  });

  // r41 ------------------------------------------------------------------
  group('r41: studio.recorder.mark', () {
    test('mark returns ok:true with label and elapsedMs', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() async {
        await recorder.stop();
        tmp.deleteSync(recursive: true);
      });

      await boot.callTool('studio.recorder.start', <String, dynamic>{});
      final result = await boot.callTool(
        'studio.recorder.mark',
        <String, dynamic>{'label': 'intro'},
      );
      final j = _callResult(result);
      expect(j['ok'], isTrue);
      expect(j['label'], 'intro');
      expect(j['elapsedMs'], isA<int>());
    });

    test('mark without label returns ok:false', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() async {
        await recorder.stop();
        tmp.deleteSync(recursive: true);
      });

      final result = await boot.callTool(
        'studio.recorder.mark',
        <String, dynamic>{'label': ''},
      );
      final j = _callResult(result);
      expect(j['ok'], isFalse);
    });

    test('marks appear in status.markers', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() async {
        await recorder.stop();
        tmp.deleteSync(recursive: true);
      });

      await boot.callTool('studio.recorder.start', <String, dynamic>{});
      await boot.callTool('studio.recorder.mark', <String, dynamic>{
        'label': 'step-1',
      });
      await boot.callTool('studio.recorder.mark', <String, dynamic>{
        'label': 'step-2',
      });

      final statusResult = await boot.callTool(
        'studio.recorder.status',
        <String, dynamic>{},
      );
      final j = _callResult(statusResult);
      final markers = j['markers'] as List;
      expect(markers, hasLength(2));
      expect(markers[0]['label'], 'step-1');
      expect(markers[1]['label'], 'step-2');
    });
  });

  // r42 ------------------------------------------------------------------
  group('r42: studio.recorder.caption', () {
    test('caption returns ok:true with text, startMs, durationMs', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() async {
        await recorder.stop();
        tmp.deleteSync(recursive: true);
      });

      await boot.callTool('studio.recorder.start', <String, dynamic>{});
      final result = await boot.callTool(
        'studio.recorder.caption',
        <String, dynamic>{'text': 'Hello world', 'durationMs': 3000},
      );
      final j = _callResult(result);
      expect(j['ok'], isTrue);
      expect(j['text'], 'Hello world');
      expect(j['startMs'], isA<int>());
      expect(j['durationMs'], 3000);
    });

    test('caption with empty text returns ok:false', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() async {
        await recorder.stop();
        tmp.deleteSync(recursive: true);
      });

      final result = await boot.callTool(
        'studio.recorder.caption',
        <String, dynamic>{'text': '  '},
      );
      final j = _callResult(result);
      expect(j['ok'], isFalse);
    });

    test('caption defaults durationMs to 2500', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() async {
        await recorder.stop();
        tmp.deleteSync(recursive: true);
      });

      await boot.callTool('studio.recorder.start', <String, dynamic>{});
      final result = await boot.callTool(
        'studio.recorder.caption',
        <String, dynamic>{'text': 'Auto duration'},
      );
      final j = _callResult(result);
      expect(j['durationMs'], 2500);
    });

    test('captions appear in status.captions', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() async {
        await recorder.stop();
        tmp.deleteSync(recursive: true);
      });

      await boot.callTool('studio.recorder.start', <String, dynamic>{});
      await boot.callTool('studio.recorder.caption', <String, dynamic>{
        'text': 'caption one',
      });
      await boot.callTool('studio.recorder.caption', <String, dynamic>{
        'text': 'caption two',
      });

      final statusResult = await boot.callTool(
        'studio.recorder.status',
        <String, dynamic>{},
      );
      final j = _callResult(statusResult);
      final captions = j['captions'] as List;
      expect(captions, hasLength(2));
      expect(captions[0]['text'], 'caption one');
      expect(captions[1]['text'], 'caption two');
    });
  });

  // r43 ------------------------------------------------------------------
  group('r43: studio.recorder.recordings.list', () {
    test('lists existing recording dirs from config root', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() => tmp.deleteSync(recursive: true));

      // Manually create two recording dirs.
      final recRoot = Directory(p.join(tmp.path, 'recordings'));
      recRoot.createSync();
      Directory(p.join(recRoot.path, '2026-01-01T10-00-00')).createSync();
      Directory(p.join(recRoot.path, '2026-01-02T10-00-00')).createSync();

      final result = await boot.callTool(
        'studio.recorder.recordings.list',
        <String, dynamic>{},
      );
      final j = _callResult(result);
      expect(j['count'], greaterThanOrEqualTo(2));
      final recs = j['recordings'] as List;
      final ids = recs.map((e) => (e as Map)['id'] as String).toList();
      expect(ids, containsAll(['2026-01-02T10-00-00', '2026-01-01T10-00-00']));
    });

    test(
      'most recent recording appears first (sorted descending by id)',
      () async {
        final (:boot, :recorder, :encoder, :tmp) = _setup();
        addTearDown(() => tmp.deleteSync(recursive: true));

        final recRoot = Directory(p.join(tmp.path, 'recordings'));
        recRoot.createSync();
        Directory(p.join(recRoot.path, '2026-01-01T08-00-00')).createSync();
        Directory(p.join(recRoot.path, '2026-01-03T08-00-00')).createSync();
        Directory(p.join(recRoot.path, '2026-01-02T08-00-00')).createSync();

        final result = await boot.callTool(
          'studio.recorder.recordings.list',
          <String, dynamic>{},
        );
        final j = _callResult(result);
        final ids =
            (j['recordings'] as List)
                .map((e) => (e as Map)['id'] as String)
                .toList();
        // First entry should be the most recent.
        expect(ids.first, '2026-01-03T08-00-00');
      },
    );

    test(
      'mp4 key present when a .mp4 file exists inside the recording dir',
      () async {
        final (:boot, :recorder, :encoder, :tmp) = _setup();
        addTearDown(() => tmp.deleteSync(recursive: true));

        final recDir = Directory(
          p.join(tmp.path, 'recordings', '2026-01-05T10-00-00'),
        );
        recDir.createSync(recursive: true);
        File(p.join(recDir.path, 'out.mp4')).writeAsBytesSync(<int>[]);
        File(p.join(recDir.path, 'frame_000000.png')).writeAsBytesSync(<int>[]);

        final result = await boot.callTool(
          'studio.recorder.recordings.list',
          <String, dynamic>{},
        );
        final j = _callResult(result);
        final recs = j['recordings'] as List;
        final entry =
            recs.firstWhere((e) => (e as Map)['id'] == '2026-01-05T10-00-00')
                as Map;
        expect(entry.containsKey('mp4'), isTrue);
        expect(entry['frameCount'], 1);
      },
    );

    test('empty config root returns count:0', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() => tmp.deleteSync(recursive: true));
      // Do NOT create the recordings directory at all.
      final result = await boot.callTool(
        'studio.recorder.recordings.list',
        <String, dynamic>{},
      );
      final j = _callResult(result);
      expect(j['count'], 0);
    });

    test('includes project recordings when scene project is active', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() => tmp.deleteSync(recursive: true));

      // Build a scene project with a recording.
      final proj = Directory(p.join(tmp.path, 'scene_proj'));
      proj.createSync();
      File(p.join(proj.path, 'scene.json')).writeAsStringSync('{}');
      final projRec = Directory(
        p.join(proj.path, 'recordings', '2026-02-01T12-00-00'),
      );
      projRec.createSync(recursive: true);
      SceneProjectScope.activePath = proj.path;

      final result = await boot.callTool(
        'studio.recorder.recordings.list',
        <String, dynamic>{},
      );
      final j = _callResult(result);
      final recs = j['recordings'] as List;
      final ids = recs.map((e) => (e as Map)['id'] as String).toList();
      expect(ids, contains('2026-02-01T12-00-00'));

      // Source should be 'project' for the project-scoped recording.
      final entry =
          recs.firstWhere((e) => (e as Map)['id'] == '2026-02-01T12-00-00')
              as Map;
      expect(entry['source'], 'project');
    });
  });

  // r44 ------------------------------------------------------------------
  group('r44: markers reset on new start', () {
    test(
      'marks from previous recording do not appear in status after new start',
      () async {
        final (:boot, :recorder, :encoder, :tmp) = _setup();
        addTearDown(() => tmp.deleteSync(recursive: true));

        // First recording — add a mark.
        await boot.callTool('studio.recorder.start', <String, dynamic>{});
        await boot.callTool('studio.recorder.mark', <String, dynamic>{
          'label': 'old-mark',
        });
        await boot.callTool('studio.recorder.stop', <String, dynamic>{});

        // Second recording — should NOT carry old marks.
        await boot.callTool('studio.recorder.start', <String, dynamic>{});
        final statusResult = await boot.callTool(
          'studio.recorder.status',
          <String, dynamic>{},
        );
        final j = _callResult(statusResult);
        final markers = j['markers'] as List;
        expect(markers, isEmpty);
        await recorder.stop();
      },
    );
  });

  // r45 ------------------------------------------------------------------
  group('r45: encode — recordingId not found returns error', () {
    test('encode with unknown id returns ok:false error', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() => tmp.deleteSync(recursive: true));

      final result = await boot.callTool(
        'studio.recorder.encode',
        <String, dynamic>{'recordingId': 'does-not-exist'},
      );
      final j = _callResult(result);
      expect(j['ok'], isFalse);
      expect(j['error'], isA<String>());
      expect((j['error'] as String).contains('does-not-exist'), isTrue);
    });

    test(
      'encode with neither recordingId nor outputDir returns ok:false',
      () async {
        final (:boot, :recorder, :encoder, :tmp) = _setup();
        addTearDown(() => tmp.deleteSync(recursive: true));

        final result = await boot.callTool(
          'studio.recorder.encode',
          <String, dynamic>{},
        );
        final j = _callResult(result);
        expect(j['ok'], isFalse);
      },
    );
  });

  // r46 ------------------------------------------------------------------
  group('r46: start → stop → resolve lifecycle', () {
    test('resolveRecordingDir finds the dir after stop', () async {
      final (:boot, :recorder, :encoder, :tmp) = _setup();
      addTearDown(() => tmp.deleteSync(recursive: true));

      final startResult = await boot.callTool(
        'studio.recorder.start',
        <String, dynamic>{},
      );
      final startJ = _callResult(startResult);
      final recId = startJ['recordingId'] as String;

      await boot.callTool('studio.recorder.stop', <String, dynamic>{});
      expect(recorder.active, isNull);

      // resolveRecordingDir must still find it via configRoot.
      final resolved = recorder.resolveRecordingDir(recId);
      expect(resolved, isNotNull);
      expect(Directory(resolved!).existsSync(), isTrue);
    });
  });
}
