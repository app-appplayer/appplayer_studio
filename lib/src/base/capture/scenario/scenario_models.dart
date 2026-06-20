/// Plain-data scenario model. A scenario is a list of [Step]s the
/// engine plays in order; each step optionally pushes overlays before
/// and/or after its action, waits `settleMs` for the UI to settle,
/// then advances. `overlayTracks` runs in parallel with the step
/// sequence on its own timeline (good for watermark / step indicator).
library;

import 'dart:convert';

class Scenario {
  Scenario({
    required this.id,
    required this.title,
    this.description,
    required this.steps,
    this.prepare = const <Step>[],
    this.overlayTracks = const <Map<String, dynamic>>[],
    this.fps = 24,
    this.record = true,
    this.recordingLabel,
    this.encodeAfter = true,
    this.encodeOptions = const <String, dynamic>{},
    this.audioTracks = const <Map<String, dynamic>>[],
    this.internal = false,
  });

  final String id;
  final String title;
  final String? description;

  /// Pre-flight steps run BEFORE `recorder.start`. Same shape as
  /// `steps` but never recorded — use for countdown overlays the
  /// author wants the user to see live (not in the final video),
  /// switching the active tab to the recording target (so Scene
  /// Studio's own UI doesn't appear in the output), staging data,
  /// etc. Empty → no pre-flight.
  final List<Step> prepare;

  final List<Step> steps;

  /// Timeline-based overlay tracks `[{at, duration, kind, ...}]` that
  /// the engine pushes / removes against an absolute time line
  /// independent of step boundaries — used for watermarks that span
  /// the whole run, intro title cards, etc.
  final List<Map<String, dynamic>> overlayTracks;
  final int fps;
  final bool record;
  final String? recordingLabel;

  /// When `true` AND `record:true`, the engine calls
  /// `EncoderService.encode` automatically after `recorder.stop()`.
  /// PNG sequence stays on disk alongside the produced MP4. Defaults
  /// to `true` so the natural author flow (record → mp4 → upload)
  /// happens in one MCP call. Set false when the author wants to
  /// keep the raw PNGs and run encoding separately.
  final bool encodeAfter;

  /// Pass-through for `EncoderService.encode` options — currently
  /// `{crf, codec, pixelFormat, outputPath}`. Empty map = ffmpeg
  /// defaults (crf 23, libx264, yuv420p, `<outputDir>/<id>.mp4`).
  final Map<String, dynamic> encodeOptions;

  /// Audio tracks muxed into the final MP4 at encode time
  /// `[{path, startMs?, volume?}]` — narration and/or background music.
  /// `path` is an on-disk audio file, `startMs` offsets it on the
  /// timeline (narration that begins a few seconds in), `volume` scales
  /// gain (1.0 = unchanged; ~0.2 for music sat under a voiceover).
  /// Multiple tracks are mixed (`amix`); output is trimmed to the shorter
  /// of video / audio (`-shortest`). Empty → silent video (unchanged).
  final List<Map<String, dynamic>> audioTracks;

  /// Marks a scenario as **internal** — its steps may dispatch tools
  /// that the host classifies as internal (create_package, bundle
  /// install / activate / uninstall). The scenario engine wraps the
  /// entire run in [ChromeBridge.withInternalCalls] when this is true
  /// so each step's `boot.callTool` call passes the per-handler
  /// `internalGuard`. Routine scenarios (default `false`) hit external
  /// tools only; internal scenarios must be invoked through the host's
  /// `run-special.sh` runner or another internal-context entry point.
  final bool internal;

  factory Scenario.fromJson(Map<String, dynamic> raw) {
    return Scenario(
      id: raw['id']?.toString() ?? 'unnamed',
      title: raw['title']?.toString() ?? raw['id']?.toString() ?? 'Scenario',
      description: raw['description']?.toString(),
      prepare: <Step>[
        for (final s in (raw['prepare'] as List? ?? const <dynamic>[]))
          if (s is Map) Step.fromJson(s.cast<String, dynamic>()),
      ],
      // `trail` is accepted as an alias for `steps`: the manual and the
      // composer agent talk about the scenario "trail", and authored JSON
      // often uses that key. Without the alias a `trail`-keyed scenario saves
      // fine but compiles to 0 steps (silent no-op in run/preview).
      steps: <Step>[
        for (final s
            in (raw['steps'] as List? ??
                raw['trail'] as List? ??
                const <dynamic>[]))
          if (s is Map) Step.fromJson(s.cast<String, dynamic>()),
      ],
      overlayTracks: <Map<String, dynamic>>[
        for (final t in (raw['overlayTracks'] as List? ?? const <dynamic>[]))
          if (t is Map) t.cast<String, dynamic>(),
      ],
      fps: (raw['fps'] as int?) ?? 24,
      record: (raw['record'] as bool?) ?? true,
      recordingLabel: raw['recordingLabel']?.toString(),
      encodeAfter: (raw['encodeAfter'] as bool?) ?? true,
      encodeOptions:
          (raw['encodeOptions'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
      // `audio` accepted as an alias for `audioTracks` (mirrors the
      // overlay/step alias philosophy — authors reach for the short word).
      audioTracks: <Map<String, dynamic>>[
        for (final t
            in (raw['audioTracks'] as List? ??
                raw['audio'] as List? ??
                const <dynamic>[]))
          if (t is Map) t.cast<String, dynamic>(),
      ],
      internal: (raw['internal'] as bool?) ?? false,
    );
  }
}

class Step {
  Step({
    required this.tool,
    this.args = const <String, dynamic>{},
    this.settleMs = 600,
    this.overlays = const <Map<String, dynamic>>[],
    this.afterAction = const <Map<String, dynamic>>[],
    this.label,
  });

  final String tool;
  final Map<String, dynamic> args;
  final int settleMs;
  final List<Map<String, dynamic>> overlays;
  final List<Map<String, dynamic>> afterAction;
  final String? label;

  factory Step.fromJson(Map<String, dynamic> raw) {
    // Accept the manual's / authored aliases so a documented-old step still
    // runs: `caption`→label, `delayMs`→settleMs, `overlay`→overlays.
    return Step(
      tool: raw['tool']?.toString() ?? '',
      args:
          (raw['args'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
      settleMs: (raw['settleMs'] as int?) ?? (raw['delayMs'] as int?) ?? 600,
      overlays: <Map<String, dynamic>>[
        for (final o
            in (raw['overlays'] as List? ??
                raw['overlay'] as List? ??
                const <dynamic>[]))
          if (o is Map) o.cast<String, dynamic>(),
      ],
      afterAction: <Map<String, dynamic>>[
        for (final o in (raw['afterAction'] as List? ?? const <dynamic>[]))
          if (o is Map) o.cast<String, dynamic>(),
      ],
      label: raw['label']?.toString() ?? raw['caption']?.toString(),
    );
  }
}

/// Convenience JSON parser for callers reading scenarios from disk.
Scenario scenarioFromJsonString(String s) =>
    Scenario.fromJson(jsonDecode(s) as Map<String, dynamic>);
