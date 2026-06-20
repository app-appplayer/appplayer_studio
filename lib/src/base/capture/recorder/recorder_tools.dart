/// Register `studio.recorder.*` MCP tools.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'encoder_service.dart';
import 'recorder_models.dart';
import 'recorder_service.dart';

mk.KernelToolResult _err(String msg) => mk.KernelToolResult(
  content: <mk.KernelContent>[
    mk.KernelTextContent(
      text: jsonEncode(<String, dynamic>{'ok': false, 'error': msg}),
    ),
  ],
);

void registerRecorderTools(
  mk.KernelServerHost boot, {
  required RecorderService recorder,
  required EncoderService encoder,
}) {
  boot.addTool(
    name: 'studio.recorder.start',
    description:
        'Begin a screen recording. Captures one PNG (or JPEG) frame '
        'per period into `<configRoot>/recordings/<id>/frame_NNNNNN.<ext>`. '
        'Identical consecutive frames are deduplicated (saves disk on '
        'static scenes). Returns `{ok, recordingId, outputDir}`. Only '
        'one recording can be active at a time — second call while one '
        'is in progress returns `{ok: false, reason: "already-recording"}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'fps': <String, dynamic>{
          'type': 'integer',
          'description': 'Frames per second (1–60, default 24).',
        },
        'area': <String, dynamic>{
          'type': 'string',
          'description':
              'Capture area: "window" (default — full shell) / "body" / '
              '"left_panel". Sub-region crop happens in Phase 1b.',
        },
        'format': <String, dynamic>{
          'type': 'string',
          'description': 'Image format: "png" (default) / "jpg".',
        },
        'label': <String, dynamic>{
          'type': 'string',
          'description':
              'Human-friendly label appended to the recording '
              'directory name. Optional.',
        },
      },
    },
    handler: (args) async {
      if (recorder.active != null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'reason': 'already-recording',
                'activeId': recorder.active!.id,
              }),
            ),
          ],
        );
      }
      final rec = await recorder.start(
        fps: (args['fps'] as int?) ?? 24,
        area: (args['area'] as String?) ?? 'window',
        format: (args['format'] as String?) ?? 'png',
        label: args['label'] as String?,
      );
      if (rec == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"reason":"start-failed"}'),
          ],
        );
      }
      // Reset markers / captions to this recording's timeline.
      _recorderStart = DateTime.now();
      _markers.clear();
      _captions.clear();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              'recordingId': rec.id,
              'outputDir': rec.outputDir,
              'fps': rec.fps,
              'format': rec.format,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.recorder.stop',
    description:
        'Stop the active recording. Returns `{ok, recordingId, '
        'frameCount, droppedDuplicates, durationMs, outputDir, '
        'ffmpegHint}`. The `ffmpegHint` is a copy-paste command the '
        'user can run to encode the PNG sequence to mp4 — Phase 2 '
        'will replace this with an in-app encoder. No-op when nothing '
        'is recording (returns `{ok: false, reason: "not-recording"}`).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      if (recorder.active == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"reason":"not-recording"}'),
          ],
        );
      }
      final rec = await recorder.stop();
      if (rec == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"reason":"stop-failed"}'),
          ],
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              ...rec.toJson(),
              'ffmpegHint': rec.ffmpegHint(),
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.recorder.encode',
    description:
        "Encode a recording's PNG sequence into an MP4 via the "
        'in-app `ffmpeg_kit_flutter_new` (LGPL build, H.264 + AAC). '
        'Runs async on a native worker — UI thread stays free, '
        'studio core tool dispatch is unaffected. Pass `recordingId` '
        '(directory name returned by `recorder.stop`) OR `outputDir` '
        '(absolute path). When `await:true` (default) the call '
        'resolves only after encoding finishes; otherwise returns '
        "immediately with `{queued: true}` and progress is observable "
        'through `studio.recorder.status` (Phase 2.1 wires this).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'recordingId': <String, dynamic>{
          'type': 'string',
          'description': 'Recording dir name (e.g. `2026-05-14T...-label`).',
        },
        'outputDir': <String, dynamic>{
          'type': 'string',
          'description':
              'Absolute path to the recording directory. Overrides '
              '`recordingId`. Use when encoding a recording from a '
              'previous session.',
        },
        'outputPath': <String, dynamic>{
          'type': 'string',
          'description': 'Target MP4 path. Default: `<recordingDir>/<id>.mp4`.',
        },
        'fps': <String, dynamic>{
          'type': 'integer',
          'description':
              'Source frame rate. Default: 24 — adjust to whatever '
              'the recorder used (the value is also stored in the '
              'recording dir as part of the id; this arg overrides).',
        },
        'crf': <String, dynamic>{
          'type': 'integer',
          'description':
              'Constant rate factor (libx264 quality). Lower = higher '
              'quality + bigger file. Default unset = ffmpeg default '
              '(23). YouTube-friendly range: 18–24.',
        },
        'audioTracks': <String, dynamic>{
          'type': 'array',
          'description':
              'Audio tracks muxed into the MP4 (narration / music). Each '
              'item: `{path, startMs?, volume?}` — `path` an on-disk audio '
              'file, `startMs` offsets it on the timeline, `volume` scales '
              'gain (1.0 = unchanged, ~0.2 for music under a voiceover). '
              'Multiple tracks are mixed; output is trimmed to the shorter '
              'of video / audio. Omit for a silent video.',
          'items': <String, dynamic>{'type': 'object'},
        },
        'await': <String, dynamic>{
          'type': 'boolean',
          'description': 'Block until encoding finishes (default true).',
        },
      },
    },
    handler: (args) async {
      final id = args['recordingId'] as String?;
      final dirArg = args['outputDir'] as String?;
      // Resolve the recording dir against the project / config recordings
      // roots (NOT `recorder.active`, which is null after `stop()`). This
      // is what lets `encode` find a project-scoped recording produced by
      // an earlier `scenario.run`.
      final outDir =
          dirArg ?? (id != null ? recorder.resolveRecordingDir(id) : null);
      if (outDir == null || outDir.isEmpty) {
        return _err(
          id != null
              ? 'recording not found: $id'
              : 'recordingId or outputDir required',
        );
      }
      // Build a synthetic Recording object pointing at the dir on
      // disk. The encoder only needs outputDir + fps + format; rest
      // of the fields are filler.
      final fps = (args['fps'] as int?) ?? 24;
      final synthetic = Recording(
        id: p.basename(outDir),
        outputDir: outDir,
        fps: fps,
        area: 'window',
        format: 'png',
        startedAt: DateTime.now(),
      );
      if (!Directory(outDir).existsSync()) {
        return _err('output directory not found: $outDir');
      }
      final waited = args['await'] as bool? ?? true;
      final crf = args['crf'] as int?;
      final outputPath = args['outputPath'] as String?;
      final audioTracks = <Map<String, dynamic>>[
        for (final t in (args['audioTracks'] as List? ?? const <dynamic>[]))
          if (t is Map) t.cast<String, dynamic>(),
      ];
      final future = encoder.encode(
        synthetic,
        outputPath: outputPath,
        crf: crf,
        audioTracks: audioTracks,
      );
      if (!waited) {
        final running = await future;
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': running != null,
                'queued': running != null,
                if (running == null) 'reason': 'encoder-busy',
                if (running != null) ...running.toJson(),
              }),
            ),
          ],
        );
      }
      final report = await future;
      if (report == null) return _err('encoder-busy');
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': report.status == 'done',
              ...report.toJson(),
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.recorder.recordings.list',
    description:
        'Enumerate persisted recordings — both the active scene '
        "project's `recordings/` (when one is open) and the global "
        '`<configRoot>/recordings/`. Each entry: `{id, source, dir, '
        'mp4?, frameCount?, durationMs?, startedAt?}`. `mp4` is set '
        'when a sibling `*.mp4` exists (post `recorder.encode`). '
        'Designed for the Scene Builder Record page binding '
        '`{{recordings}}` so the user can pick a finished video to '
        'replay without remembering paths.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final entries = <Map<String, dynamic>>[];
      final sources = <({String dir, String source})>[
        if (recorder.projectRecordingsRoot != null)
          (dir: recorder.projectRecordingsRoot!, source: 'project'),
        (dir: recorder.configRecordingsRoot, source: 'user'),
      ];
      for (final src in sources) {
        final dir = Directory(src.dir);
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          if (entity is! Directory) continue;
          final id = p.basename(entity.path);
          int frameCount = 0;
          String? mp4Path;
          await for (final f in entity.list()) {
            if (f is! File) continue;
            final base = p.basename(f.path);
            if (base.endsWith('.mp4')) {
              mp4Path = f.path;
            } else if (base.startsWith('frame_')) {
              frameCount++;
            }
          }
          entries.add(<String, dynamic>{
            'id': id,
            'source': src.source,
            'dir': entity.path,
            if (mp4Path != null) 'mp4': mp4Path,
            'frameCount': frameCount,
          });
        }
      }
      // Most recent first (id format starts with ISO timestamp).
      entries.sort((a, b) => (b['id'] as String).compareTo(a['id'] as String));
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'count': entries.length,
              'recordings': entries,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.recorder.status',
    description:
        'Snapshot of the active recording — `{active: true, id, fps, '
        'area, format, frameCount, droppedDuplicates, elapsedMs, '
        'markers, captions}` when a recording is in progress, '
        '`{active: false}` otherwise. Use to poll without consuming '
        'the recording.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final rec = recorder.statusSnapshot();
      if (rec == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"active":false}'),
          ],
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'active': true,
              ...rec.toJson(),
              'markers':
                  _markers
                      .map((m) => m.toJson(_recorderStart ?? DateTime.now()))
                      .toList(),
              'captions':
                  _captions
                      .map((c) => c.toJson(_recorderStart ?? DateTime.now()))
                      .toList(),
            }),
          ),
        ],
      );
    },
  );

  // ── studio.recorder.mark ────────────────────────────────────────
  // Drop a named timeline marker at the current moment. Markers
  // survive until the next `studio.recorder.start` and are surfaced
  // through `studio.recorder.status` so downstream encoders /
  // editors can chapter the recording.
  boot.addTool(
    name: 'studio.recorder.mark',
    description:
        'Drop a chapter / scene marker at the current moment. '
        '`label` is a free-form identifier (e.g. `intro`, `step-2`). '
        'Markers persist on `studio.recorder.status` until the next '
        '`start`. Returns `{ok, label, elapsedMs}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'label': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['label'],
    },
    handler: (args) async {
      final label = (args['label'] as String?)?.trim() ?? '';
      if (label.isEmpty) return _err('label required');
      final now = DateTime.now();
      _recorderStart ??= now;
      final marker = _RecorderMark(label: label, timestamp: now);
      _markers.add(marker);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              'label': label,
              'elapsedMs': now.difference(_recorderStart!).inMilliseconds,
            }),
          ),
        ],
      );
    },
  );

  // ── studio.recorder.caption ─────────────────────────────────────
  // Push an on-screen caption for the current frame range. The
  // caption is logged to `status` and an overlay can render it via
  // `studio.overlay.push` if a visible burn-in is required.
  boot.addTool(
    name: 'studio.recorder.caption',
    description:
        'Log a caption (subtitle / narration text) onto the active '
        'recording timeline. `text` shows in `status.captions[]` '
        'with `startMs` / `durationMs` so post-process / overlay can '
        'render it. Returns `{ok, text, startMs, durationMs}`. '
        'Optional `durationMs` (default 2500) controls how long the '
        'caption persists. To make it visible during recording, '
        'pair with `studio.overlay.push`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'text': <String, dynamic>{'type': 'string'},
        'durationMs': <String, dynamic>{'type': 'integer', 'default': 2500},
      },
      'required': <String>['text'],
    },
    handler: (args) async {
      final text = (args['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) return _err('text required');
      final duration = (args['durationMs'] as num?)?.toInt() ?? 2500;
      final now = DateTime.now();
      _recorderStart ??= now;
      final caption = _RecorderCaption(
        text: text,
        timestamp: now,
        durationMs: duration,
      );
      _captions.add(caption);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              'text': text,
              'startMs': now.difference(_recorderStart!).inMilliseconds,
              'durationMs': duration,
            }),
          ),
        ],
      );
    },
  );
}

DateTime? _recorderStart;
final List<_RecorderMark> _markers = <_RecorderMark>[];
final List<_RecorderCaption> _captions = <_RecorderCaption>[];

class _RecorderMark {
  _RecorderMark({required this.label, required this.timestamp});
  final String label;
  final DateTime timestamp;
  Map<String, dynamic> toJson(DateTime origin) => <String, dynamic>{
    'label': label,
    'elapsedMs': timestamp.difference(origin).inMilliseconds,
  };
}

class _RecorderCaption {
  _RecorderCaption({
    required this.text,
    required this.timestamp,
    required this.durationMs,
  });
  final String text;
  final DateTime timestamp;
  final int durationMs;
  Map<String, dynamic> toJson(DateTime origin) => <String, dynamic>{
    'text': text,
    'startMs': timestamp.difference(origin).inMilliseconds,
    'durationMs': durationMs,
  };
}
