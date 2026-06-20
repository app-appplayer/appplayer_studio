/// `ScenarioEngine` — sequential step runner for [Scenario]. Each
/// step (1) pushes any `overlays` declared before the action, (2)
/// dispatches the step's MCP tool via the kernel `ServerBootstrap`,
/// (3) waits `settleMs` for the UI to settle so capture frames are
/// stable, (4) pushes `afterAction` overlays, (5) clears step-scoped
/// overlays before advancing. Recording (when `scenario.record` is
/// true) wraps the whole run via `studio.recorder.start` / `stop`.
///
/// Engine is dependency-light: takes the [RecorderService] and
/// [OverlayController] directly so the scenario tools don't have to
/// re-resolve them through MCP each step. The runtime tool dispatch
/// goes through `ServerBootstrap.server.callTool` so every step has
/// the SAME entry point an external LLM would use — no studio-side
/// shortcuts that would diverge from production dispatch paths.
library;

import 'dart:async';

import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../../main/chrome_bridge.dart';
import '../overlay/overlay_controller.dart';
import '../overlay/overlay_models.dart';
import '../recorder/encoder_service.dart';
import '../recorder/recorder_models.dart';
import '../recorder/recorder_service.dart';
import 'scenario_models.dart';

class ScenarioRunReport {
  ScenarioRunReport({
    required this.scenarioId,
    required this.stepsExecuted,
    required this.elapsedMs,
    this.recording,
    this.encoding,
    this.encodeReason,
    this.error,
  });
  final String scenarioId;
  final int stepsExecuted;
  final int elapsedMs;
  final Recording? recording;
  final EncodingProgress? encoding;
  final String? encodeReason;
  final String? error;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'scenarioId': scenarioId,
    'stepsExecuted': stepsExecuted,
    'elapsedMs': elapsedMs,
    if (recording != null) ...<String, dynamic>{
      'recording': recording!.toJson(),
      // Keep the ffmpeg CLI hint even when in-app encoding ran —
      // lets users re-encode with different settings outside the
      // app if they want to.
      'ffmpegHint': recording!.ffmpegHint(),
    },
    if (encoding != null) 'encoding': encoding!.toJson(),
    if (encodeReason != null) 'encodeReason': encodeReason,
    if (error != null) 'error': error,
  };
}

class ScenarioEngine {
  ScenarioEngine({
    required mk.KernelServerHost boot,
    required RecorderService recorder,
    required EncoderService encoder,
    required OverlayController overlays,
    required ChromeBridge chromeBridge,
  }) : _boot = boot,
       _recorder = recorder,
       _encoder = encoder,
       _overlays = overlays,
       _chromeBridge = chromeBridge;

  final mk.KernelServerHost _boot;
  final RecorderService _recorder;
  final EncoderService _encoder;
  final OverlayController _overlays;
  final ChromeBridge _chromeBridge;
  bool _running = false;

  bool get running => _running;

  /// Execute [scenario]. When `dryRun` is true, the engine performs
  /// every step's dispatch + overlay sequence WITHOUT starting the
  /// recorder — used to verify a scenario plays cleanly before
  /// committing to a recording.
  ///
  /// When `scenario.internal == true`, the entire run (including
  /// `prepare`) executes inside [ChromeBridge.withInternalCalls], so
  /// every `boot.callTool` step passes the per-handler
  /// `internalGuard`. Routine scenarios (default `internal: false`)
  /// run with the flag untouched.
  Future<ScenarioRunReport> run(
    Scenario scenario, {
    bool dryRun = false,
  }) async {
    if (scenario.internal) {
      return _chromeBridge.withInternalCalls(
        () => _runImpl(scenario, dryRun: dryRun),
      );
    }
    return _runImpl(scenario, dryRun: dryRun);
  }

  Future<ScenarioRunReport> _runImpl(
    Scenario scenario, {
    bool dryRun = false,
  }) async {
    if (_running) {
      return ScenarioRunReport(
        scenarioId: scenario.id,
        stepsExecuted: 0,
        elapsedMs: 0,
        error: 'engine-busy',
      );
    }
    // Reject empty scenarios — `prepare` + `steps` + `overlayTracks`
    // all empty means there is nothing for the engine to do, but the
    // recorder.start/stop path can stall (no settle anchors to advance
    // the time line). Skip the run entirely instead of producing a
    // multi-minute idle recording.
    if (scenario.prepare.isEmpty &&
        scenario.steps.isEmpty &&
        scenario.overlayTracks.isEmpty) {
      return ScenarioRunReport(
        scenarioId: scenario.id,
        stepsExecuted: 0,
        elapsedMs: 0,
        error: 'empty-scenario',
      );
    }
    _running = true;
    final sw = Stopwatch()..start();
    final pushedIds = <String>[];
    Recording? recording;
    try {
      // Pre-flight — runs BEFORE recorder.start so overlays the
      // author pushes here are NOT captured. Use for countdown
      // banners shown live to the user, switching the active tab to
      // the recording target, staging data, etc.
      for (final step in scenario.prepare) {
        if (!_running) break;
        final stepOverlayIds = <String>[];
        for (final o in step.overlays) {
          try {
            final id = _overlays.push((id) => OverlaySpec.fromJson(id, o));
            stepOverlayIds.add(id);
          } catch (_) {
            /* swallow malformed overlay */
          }
        }
        if (step.tool.isNotEmpty) {
          try {
            await _boot.callTool(step.tool, step.args);
          } catch (_) {
            /* swallow per-step errors */
          }
        }
        if (step.settleMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: step.settleMs));
        }
        for (final id in stepOverlayIds) {
          try {
            _overlays.remove(id);
          } catch (_) {
            /* swallow */
          }
        }
      }
      if (!dryRun && scenario.record) {
        recording = await _recorder.start(
          fps: scenario.fps,
          label: scenario.recordingLabel ?? scenario.id,
        );
      }
      // Overlay tracks — schedule absolute-time pushes / removes.
      final trackTimers = <Timer>[];
      for (final track in scenario.overlayTracks) {
        final at = (track['at'] as int?) ?? 0;
        final duration = (track['duration'] as int?) ?? 4000;
        trackTimers.add(
          Timer(Duration(milliseconds: at), () {
            if (!_running) return;
            try {
              final id = _overlays.push(
                (id) => OverlaySpec.fromJson(id, _stripSchedKeys(track)),
              );
              pushedIds.add(id);
              Timer(Duration(milliseconds: duration), () {
                try {
                  _overlays.remove(id);
                } catch (_) {
                  /* swallow */
                }
              });
            } catch (_) {
              /* swallow */
            }
          }),
        );
      }
      var executed = 0;
      for (final step in scenario.steps) {
        if (!_running) break;
        // Pre-action overlays.
        final stepOverlayIds = <String>[];
        for (final o in step.overlays) {
          try {
            final id = _overlays.push((id) => OverlaySpec.fromJson(id, o));
            stepOverlayIds.add(id);
          } catch (_) {
            /* swallow malformed overlay */
          }
        }
        // Dispatch the tool — empty `tool` is allowed (pure pause).
        if (step.tool.isNotEmpty) {
          try {
            await _boot.callTool(step.tool, step.args);
          } catch (_) {
            /* swallow per-step errors; engine carries on */
          }
        }
        // Settle delay — gives the UI a beat to apply the action so
        // recorder frames are stable + overlays don't race the result.
        if (step.settleMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: step.settleMs));
        }
        // After-action overlays (e.g. check mark on the just-clicked
        // tool). Pushed before the step-scoped ones clear so they
        // visually replace the cue.
        for (final o in step.afterAction) {
          try {
            final id = _overlays.push((id) => OverlaySpec.fromJson(id, o));
            stepOverlayIds.add(id);
          } catch (_) {
            /* swallow */
          }
        }
        // Hold the after-action overlays briefly so they're recorded
        // before clearing — fixed 400ms; in Phase 3b authors can tune
        // per-step via `holdMs`.
        if (step.afterAction.isNotEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        // Clear step-scoped overlays. Watermark / step_indicator that
        // live on tracks stay up.
        for (final id in stepOverlayIds) {
          try {
            _overlays.remove(id);
          } catch (_) {
            /* swallow */
          }
        }
        executed += 1;
      }
      // Cancel any unfired track timers — scenario finished early or
      // the tracks' `at` was beyond the run length.
      for (final t in trackTimers) {
        t.cancel();
      }
      // Best-effort overlay clear for any track that's still up.
      for (final id in pushedIds) {
        try {
          _overlays.remove(id);
        } catch (_) {
          /* swallow */
        }
      }
      if (!dryRun && scenario.record) {
        recording = await _recorder.stop() ?? recording;
      }
      // Auto-encode after a successful recording. Runs on a native
      // worker via `EncoderService.encode` — UI thread stays free
      // for the user's normal studio work. When the encoder is busy
      // (someone else already triggered an encode) we record that in
      // the report and the PNG sequence stays on disk for retry.
      EncodingProgress? encoding;
      String? encodeReason;
      final encodeCondition =
          !dryRun &&
          scenario.record &&
          scenario.encodeAfter &&
          recording != null;
      if (encodeCondition) {
        final opts = scenario.encodeOptions;
        // Audio is a first-class scenario field; `encodeOptions.audioTracks`
        // is accepted as a fallback for authors who keep all encode config
        // together.
        final audioTracks =
            scenario.audioTracks.isNotEmpty
                ? scenario.audioTracks
                : <Map<String, dynamic>>[
                  for (final t
                      in (opts['audioTracks'] as List? ?? const <dynamic>[]))
                    if (t is Map) t.cast<String, dynamic>(),
                ];
        try {
          encoding = await _encoder.encode(
            recording,
            outputPath: opts['outputPath']?.toString(),
            codec: opts['codec']?.toString() ?? 'libx264',
            pixelFormat: opts['pixelFormat']?.toString() ?? 'yuv420p',
            crf: opts['crf'] is int ? opts['crf'] as int : null,
            audioTracks: audioTracks,
          );
          if (encoding == null) encodeReason = 'encoder-busy';
        } catch (e) {
          encodeReason = 'encode-threw: $e';
        }
      } else if (!dryRun && scenario.record && recording != null) {
        encodeReason = 'auto-encode disabled (encodeAfter=false)';
      }
      sw.stop();
      return ScenarioRunReport(
        scenarioId: scenario.id,
        stepsExecuted: executed,
        elapsedMs: sw.elapsedMilliseconds,
        recording: recording,
        encoding: encoding,
        encodeReason: encodeReason,
      );
    } catch (e) {
      sw.stop();
      if (recording != null) {
        try {
          await _recorder.stop();
        } catch (_) {
          /* swallow */
        }
      }
      return ScenarioRunReport(
        scenarioId: scenario.id,
        stepsExecuted: 0,
        elapsedMs: sw.elapsedMilliseconds,
        error: e.toString(),
      );
    } finally {
      _running = false;
    }
  }

  Map<String, dynamic> _stripSchedKeys(Map<String, dynamic> raw) {
    return <String, dynamic>{
      for (final entry in raw.entries)
        if (entry.key != 'at' && entry.key != 'duration')
          entry.key: entry.value,
    };
  }
}
