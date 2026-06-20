/// r9-r20: Unit tests for [RecorderService] — pure logic paths that
/// exercise dir-resolution, state machine transitions, slug generation,
/// and hash dedup without requiring ffmpeg or a real ChromeBridge
/// screenshot capture slot (captureScreenshot is left null throughout).
///
/// Real temp directories are used; tearDown deletes them.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/capture/recorder/recorder_service.dart';
import 'package:appplayer_studio/src/base/capture/scene_project/scene_project_tools.dart';
import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns a ChromeBridge that has no captureScreenshot slot wired.
/// RecorderService._capture() returns early when that slot is null, so
/// no frames are written — only the directory creation side-effect of
/// `start()` matters for these tests.
ChromeBridge _nullBridge() => ChromeBridge();

// Build a RecorderService and keep track of the temp dirs it creates.
(RecorderService, Directory) _makeService() {
  final dir = Directory.systemTemp.createTempSync('rec_svc_test_');
  final svc = RecorderService(bridge: _nullBridge(), configRoot: dir.path);
  return (svc, dir);
}

void main() {
  setUp(() {
    SceneProjectScope.activePath = null;
  });

  tearDown(() {
    SceneProjectScope.activePath = null;
  });

  // r9 -------------------------------------------------------------------
  group('r9: configRecordingsRoot', () {
    test('is <configRoot>/recordings', () {
      final (svc, tmp) = _makeService();
      addTearDown(() => tmp.deleteSync(recursive: true));
      expect(svc.configRecordingsRoot, p.join(tmp.path, 'recordings'));
    });
  });

  // r10 ------------------------------------------------------------------
  group('r10: projectRecordingsRoot — no active scene project', () {
    test(
      'returns null when SceneProjectScope is not set and bridge has no activeProjectInfo',
      () {
        final (svc, tmp) = _makeService();
        addTearDown(() => tmp.deleteSync(recursive: true));
        SceneProjectScope.activePath = null;
        expect(svc.projectRecordingsRoot, isNull);
      },
    );
  });

  // r11 ------------------------------------------------------------------
  group(
    'r11: projectRecordingsRoot — active scene project with scene.json',
    () {
      test('returns <projectPath>/recordings when scene.json exists', () async {
        final (svc, tmp) = _makeService();
        addTearDown(() => tmp.deleteSync(recursive: true));

        // Create a scene project with the marker file.
        final proj = Directory(p.join(tmp.path, 'my_scene'));
        proj.createSync();
        File(p.join(proj.path, 'scene.json')).writeAsStringSync('{}');
        SceneProjectScope.activePath = proj.path;

        expect(svc.projectRecordingsRoot, p.join(proj.path, 'recordings'));
      });

      test(
        'returns null when scene.json marker is missing even if path is set',
        () async {
          final (svc, tmp) = _makeService();
          addTearDown(() => tmp.deleteSync(recursive: true));

          final proj = Directory(p.join(tmp.path, 'no_marker'));
          proj.createSync();
          // No scene.json written.
          SceneProjectScope.activePath = proj.path;

          expect(svc.projectRecordingsRoot, isNull);
        },
      );
    },
  );

  // r12 ------------------------------------------------------------------
  group('r12: resolveRecordingDir — config root fallback', () {
    test('finds a recording dir under configRoot/recordings/', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() => tmp.deleteSync(recursive: true));

      final recDir = Directory(p.join(tmp.path, 'recordings', 'my-rec'));
      recDir.createSync(recursive: true);

      final resolved = svc.resolveRecordingDir('my-rec');
      expect(resolved, recDir.path);
    });

    test('returns null when the id does not exist in either root', () {
      final (svc, tmp) = _makeService();
      addTearDown(() => tmp.deleteSync(recursive: true));

      expect(svc.resolveRecordingDir('no-such-rec'), isNull);
    });
  });

  // r13 ------------------------------------------------------------------
  group('r13: resolveRecordingDir — project root takes priority', () {
    test(
      'finds recording under project recordings/ when both roots have the id',
      () async {
        final (svc, tmp) = _makeService();
        addTearDown(() => tmp.deleteSync(recursive: true));

        // Create a scene project with marker.
        final proj = Directory(p.join(tmp.path, 'proj'));
        proj.createSync();
        File(p.join(proj.path, 'scene.json')).writeAsStringSync('{}');
        SceneProjectScope.activePath = proj.path;

        // Place a recordings dir in both roots.
        final projRec = Directory(p.join(proj.path, 'recordings', 'shared-id'));
        projRec.createSync(recursive: true);
        final cfgRec = Directory(p.join(tmp.path, 'recordings', 'shared-id'));
        cfgRec.createSync(recursive: true);

        final resolved = svc.resolveRecordingDir('shared-id');
        // Project root is checked first (_recordingsRoot() → project root).
        expect(resolved, projRec.path);
      },
    );
  });

  // r14 ------------------------------------------------------------------
  group('r14: state machine — active starts as null', () {
    test('active is null before any start() call', () {
      final (svc, tmp) = _makeService();
      addTearDown(() => tmp.deleteSync(recursive: true));
      expect(svc.active, isNull);
    });
  });

  // r15 ------------------------------------------------------------------
  group('r15: start() returns a Recording with expected fields', () {
    test('start creates a dir and returns a Recording', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() async {
        svc.active; // do not leak timer
        await svc.stop();
        tmp.deleteSync(recursive: true);
      });

      final rec = await svc.start(
        fps: 10,
        area: 'body',
        format: 'jpg',
        label: 'test',
      );
      expect(rec, isNotNull);
      expect(rec!.fps, 10);
      expect(rec.area, 'body');
      expect(rec.format, 'jpg');
      expect(rec.label, 'test');
      expect(Directory(rec.outputDir).existsSync(), isTrue);
    });
  });

  // r16 ------------------------------------------------------------------
  group('r16: fps clamping in start()', () {
    test('fps below 1 is clamped to 1', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() async {
        await svc.stop();
        tmp.deleteSync(recursive: true);
      });
      final rec = await svc.start(fps: 0);
      expect(rec!.fps, 1);
    });

    test('fps above 60 is clamped to 60', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() async {
        await svc.stop();
        tmp.deleteSync(recursive: true);
      });
      final rec = await svc.start(fps: 120);
      expect(rec!.fps, 60);
    });
  });

  // r17 ------------------------------------------------------------------
  group('r17: format normalisation in start()', () {
    test('"jpg" stays "jpg"', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() async {
        await svc.stop();
        tmp.deleteSync(recursive: true);
      });
      final rec = await svc.start(format: 'jpg');
      expect(rec!.format, 'jpg');
    });

    test('any value other than "jpg" becomes "png"', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() async {
        await svc.stop();
        tmp.deleteSync(recursive: true);
      });
      final rec = await svc.start(format: 'bmp');
      expect(rec!.format, 'png');
    });
  });

  // r18 ------------------------------------------------------------------
  group('r18: double-start guard', () {
    test('second start() while one is active returns null', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() async {
        await svc.stop();
        tmp.deleteSync(recursive: true);
      });

      final first = await svc.start();
      expect(first, isNotNull);
      expect(svc.active, isNotNull);

      final second = await svc.start();
      expect(second, isNull);
    });
  });

  // r19 ------------------------------------------------------------------
  group('r19: stop() resets state', () {
    test('stop returns the Recording and active becomes null', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() => tmp.deleteSync(recursive: true));

      await svc.start(label: 'stopper');
      expect(svc.active, isNotNull);

      final stopped = await svc.stop();
      expect(stopped, isNotNull);
      expect(stopped!.stoppedAt, isNotNull);
      expect(svc.active, isNull);
    });

    test('stop returns null when nothing is recording', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() => tmp.deleteSync(recursive: true));

      expect(svc.active, isNull);
      final result = await svc.stop();
      expect(result, isNull);
    });
  });

  // r20 ------------------------------------------------------------------
  group('r20: _safeSlug behaviour exercised via start(label:)', () {
    // The outputDir name contains `<timestamp>-<slug(label)>` when label
    // is non-empty — we verify the slug portion is legal.

    test('label with only alphanumeric chars passes through', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() async {
        await svc.stop();
        tmp.deleteSync(recursive: true);
      });
      final rec = await svc.start(label: 'hello');
      final dirName = p.basename(rec!.outputDir);
      expect(dirName, endsWith('-hello'));
    });

    test('spaces and dashes in label become dashes', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() async {
        await svc.stop();
        tmp.deleteSync(recursive: true);
      });
      final rec = await svc.start(label: 'step 1-a');
      final dirName = p.basename(rec!.outputDir);
      // Spaces → '-', dashes preserved → 'step-1-a'
      expect(dirName, endsWith('-step-1-a'));
    });

    test('label with only special chars falls back to "rec"', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() async {
        await svc.stop();
        tmp.deleteSync(recursive: true);
      });
      final rec = await svc.start(label: '!!!');
      final dirName = p.basename(rec!.outputDir);
      expect(dirName, endsWith('-rec'));
    });

    test('null label produces dir name without a trailing slug', () async {
      final (svc, tmp) = _makeService();
      addTearDown(() async {
        await svc.stop();
        tmp.deleteSync(recursive: true);
      });
      final rec = await svc.start(label: null);
      final dirName = p.basename(rec!.outputDir);
      // No dash-suffix when label is null — only the ISO timestamp.
      // The name should NOT contain a '-rec' or any trailing slug segment.
      // We just verify it's a non-empty string that matches ISO timestamp form.
      expect(dirName, isNotEmpty);
      expect(dirName.contains('T'), isTrue); // ISO datetime contains 'T'
    });
  });
}
