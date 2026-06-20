/// Frame-capture timer that emits a PNG (or JPEG) sequence to disk.
///
/// Driven by `studio.recorder.start` / `stop` MCP tools. Captures the
/// shell's RepaintBoundary via `ChromeBridge.captureScreenshot`. One
/// `RecorderService` instance per host (singleton-by-convention); the
/// service refuses to start a second recording while one is active.
///
/// Phase 1 ships PNG sequence + ffmpeg hint. Phase 2 will swap the
/// disk-write loop for an in-app mp4 encoder.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../main/chrome_bridge.dart';
import '../scene_project/scene_project_tools.dart';
import 'recorder_models.dart';

class RecorderService {
  RecorderService({required ChromeBridge bridge, required String configRoot})
    : _bridge = bridge,
      _configRoot = configRoot;

  final ChromeBridge _bridge;
  final String _configRoot;

  /// Root directory for new recordings. Prefers the active tab's
  /// Scene Builder project (`<projectPath>/recordings/`) when that
  /// project carries a `scene.json` marker, otherwise falls back to
  /// `<configRoot>/recordings/`. Same shape as the chrome's project-
  /// scoped builder lifecycle — recordings + scenarios always live
  /// inside the user's project folder when one is open.
  /// Configured root (`<configRoot>/recordings/`). Public so the
  /// recordings-list tool can enumerate the fallback location.
  String get configRecordingsRoot => p.join(_configRoot, 'recordings');

  /// Project-scoped recordings root when the active tab carries a
  /// `scene.json` marker — null otherwise.
  String? get projectRecordingsRoot {
    final info = SceneProjectScope.info() ?? _bridge.activeProjectInfo?.call();
    final projectPath = info?['projectPath']?.toString();
    if (projectPath != null && projectPath.isNotEmpty) {
      final marker = File(p.join(projectPath, 'scene.json'));
      if (marker.existsSync()) return p.join(projectPath, 'recordings');
    }
    return null;
  }

  String _recordingsRoot() {
    final info = SceneProjectScope.info() ?? _bridge.activeProjectInfo?.call();
    final projectPath = info?['projectPath']?.toString();
    if (projectPath != null && projectPath.isNotEmpty) {
      final marker = File(p.join(projectPath, 'scene.json'));
      if (marker.existsSync()) {
        return p.join(projectPath, 'recordings');
      }
    }
    return p.join(_configRoot, 'recordings');
  }

  /// Resolve an on-disk recording directory by its id (the dir name
  /// `recorder.start` / `stop` returned). Checks the active project's
  /// `recordings/` first, then the config fallback — so `recorder.encode`
  /// finds a recording regardless of whether a scene project was open when
  /// it was captured. Returns null when no matching dir exists in either
  /// root. (The previous resolver derived the root from `recorder.active`,
  /// which is null after `stop()` — leaving a bare relative `recordings/<id>`
  /// that never resolved.)
  String? resolveRecordingDir(String id) {
    final candidates = <String>[
      p.join(_recordingsRoot(), id),
      p.join(_configRoot, 'recordings', id),
    ];
    for (final dir in candidates) {
      if (Directory(dir).existsSync()) return dir;
    }
    return null;
  }

  Recording? _active;
  Timer? _timer;
  Uint8List? _lastFrameBytes;
  int _lastFrameHash = 0;
  bool _capturing = false;

  Recording? get active => _active;

  /// Begin a new recording. Returns the [Recording] on success or
  /// null when one is already active.
  Future<Recording?> start({
    int fps = 24,
    String area = 'window',
    String format = 'png',
    String? label,
  }) async {
    if (_active != null) return null;
    final clampedFps = fps.clamp(1, 60);
    final ts =
        DateTime.now()
            .toUtc()
            .toIso8601String()
            .replaceAll(':', '-')
            .split('.')
            .first;
    final dirName =
        label == null || label.isEmpty ? ts : '$ts-${_safeSlug(label)}';
    final dir = Directory(p.join(_recordingsRoot(), dirName));
    await dir.create(recursive: true);
    final rec = Recording(
      id: dirName,
      outputDir: dir.path,
      fps: clampedFps,
      area: area,
      format: format == 'jpg' ? 'jpg' : 'png',
      startedAt: DateTime.now(),
      label: label,
    );
    _active = rec;
    _lastFrameBytes = null;
    _lastFrameHash = 0;
    final periodMs = (1000 / clampedFps).round();
    _timer = Timer.periodic(Duration(milliseconds: periodMs), (_) => _tick());
    return rec;
  }

  /// Stop the active recording. Returns the finalised [Recording] or
  /// null when nothing is recording.
  Future<Recording?> stop() async {
    final rec = _active;
    if (rec == null) return null;
    _timer?.cancel();
    _timer = null;
    // Drain one final tick so the last visible frame lands on disk
    // (the periodic timer might fire mid-frame; this guarantees the
    // closing frame is present regardless).
    await _capture(rec);
    rec.stoppedAt = DateTime.now();
    _active = null;
    _lastFrameBytes = null;
    return rec;
  }

  Recording? statusSnapshot() => _active;

  Future<void> _tick() async {
    final rec = _active;
    if (rec == null) return;
    if (_capturing) return; // skip if previous capture still running
    _capturing = true;
    try {
      await _capture(rec);
    } catch (_) {
      /* swallow — recorder is best-effort */
    } finally {
      _capturing = false;
    }
  }

  Future<void> _capture(Recording rec) async {
    final fn = _bridge.captureScreenshot;
    if (fn == null) return;
    final bytes = await fn(pixelRatio: 1.0);
    if (bytes == null) return;
    // Dedup — if the frame is byte-identical (or hash-identical) to the
    // previous one, skip writing. Saves disk on static scenes.
    final h = _fastHash(bytes);
    if (h == _lastFrameHash &&
        _lastFrameBytes != null &&
        _lastFrameBytes!.length == bytes.length) {
      rec.droppedDuplicates += 1;
      return;
    }
    _lastFrameHash = h;
    _lastFrameBytes = bytes;
    final fname =
        'frame_${rec.frameCount.toString().padLeft(6, '0')}.${rec.format}';
    final file = File(p.join(rec.outputDir, fname));
    await file.writeAsBytes(bytes, flush: false);
    rec.frameCount += 1;
    rec.bytesWritten += bytes.length;
  }

  /// Fast 32-bit FNV-1a over a downsampled byte stride. Good enough
  /// to detect identical frames; collisions are tolerable (we'd just
  /// skip a frame that was actually different — visually invisible
  /// at high fps).
  int _fastHash(Uint8List bytes) {
    var hash = 0x811c9dc5;
    final step = bytes.length > 4096 ? bytes.length ~/ 1024 : 1;
    for (var i = 0; i < bytes.length; i += step) {
      hash = (hash ^ bytes[i]) & 0xffffffff;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  String _safeSlug(String s) {
    final lower = s.trim().toLowerCase();
    final cleaned = StringBuffer();
    for (final code in lower.codeUnits) {
      if ((code >= 0x30 && code <= 0x39) ||
          (code >= 0x61 && code <= 0x7a) ||
          code == 0x5f) {
        cleaned.writeCharCode(code);
      } else if (code == 0x20 || code == 0x2d) {
        cleaned.writeCharCode(0x2d);
      }
    }
    final out = cleaned.toString();
    return out.isEmpty ? 'rec' : out;
  }
}
