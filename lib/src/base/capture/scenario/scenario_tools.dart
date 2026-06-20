/// Register `studio.scenario.*` MCP tools backed by [ScenarioEngine].
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'scenario_engine.dart';
import 'scenario_models.dart';

/// Resolver the host wires from its bundle registry — returns the
/// list of `<dir>/<id>.json` directories the scenario tools should
/// search (and merge their listings). Empty / null means
/// configRoot/scenarios/ only.
typedef SeedScenarioDirsResolver = List<String> Function();

/// Optional resolver for an "active project scenarios" directory. The
/// host wires this from `chromeBridge.activeProjectInfo` — when the
/// active tab's `currentProject` carries a `scene.json` marker, we
/// return `<projectPath>/scenarios/` so scene project scenarios
/// surface in `list` (with `source:'project'`) and `run({id})` finds
/// them ahead of user / seed dirs.
typedef ActiveProjectScenariosResolver = String? Function();

void registerScenarioTools(
  mk.KernelServerHost boot, {
  required ScenarioEngine engine,
  required String configRoot,
  SeedScenarioDirsResolver? seedScenarioDirs,
  ActiveProjectScenariosResolver? activeProjectScenariosDir,
}) {
  // Resolve `<id>.json` against the same source set used by list /
  // run — project (when open) first, then user, then each seed dir.
  // Returns null when not found in any source.
  Future<File?> resolveScenarioFile(String id) async {
    final projectDir = activeProjectScenariosDir?.call();
    final candidates = <String>[
      if (projectDir != null) p.join(projectDir, '$id.json'),
      p.join(configRoot, 'scenarios', '$id.json'),
      for (final d in (seedScenarioDirs?.call() ?? const <String>[]))
        p.join(d, '$id.json'),
    ];
    for (final c in candidates) {
      final f = File(c);
      if (await f.exists()) return f;
    }
    return null;
  }

  boot.addTool(
    name: 'studio.scenario.run',
    description:
        'Execute a scenario — a sequence of MCP tool dispatches '
        'interleaved with overlay annotations and settle delays. '
        'Pass `scenario` inline (full JSON object) OR `path` (read '
        'from disk; falls back to `<configRoot>/scenarios/<id>.json`). '
        '`dryRun:true` plays every step + overlay but skips '
        '`studio.recorder.start` so the user can verify a script '
        'before committing to a recording. When `record:true` and '
        '`encodeAfter:true` (both default), the engine auto-encodes '
        'the recorded PNG sequence to MP4 via the in-app FFmpeg as '
        "the last step — the run report's `encoding.outputPath` "
        'points at the produced `.mp4`. Returns `{stepsExecuted, '
        'elapsedMs, recording?, encoding?, ffmpegHint?}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'scenario': <String, dynamic>{
          'description': 'Inline scenario object (overrides `path`).',
        },
        'path': <String, dynamic>{
          'type': 'string',
          'description':
              'Path to a `.json` scenario file. Relative paths '
              'resolve against `<configRoot>/scenarios/`.',
        },
        'id': <String, dynamic>{
          'type': 'string',
          'description':
              'Scenario id — resolved against user scenarios first '
              '(`<configRoot>/scenarios/<id>.json`) then any seed '
              'scenarios shipped by installed bundles. Use '
              '`studio.scenario.list` to see available ids + their '
              'source.',
        },
        'dryRun': <String, dynamic>{
          'type': 'boolean',
          'description': 'Skip recorder start/stop. Default false.',
        },
      },
    },
    handler: (args) async {
      Scenario? scenario;
      final raw = args['scenario'];
      if (raw is Map) {
        try {
          scenario = Scenario.fromJson(raw.cast<String, dynamic>());
        } catch (e) {
          return _err('scenario parse failed: $e');
        }
      } else if (raw is String && raw.trim().isNotEmpty) {
        try {
          scenario = scenarioFromJsonString(raw);
        } catch (e) {
          return _err('scenario JSON parse failed: $e');
        }
      } else {
        final path = args['path'] as String?;
        final id = args['id'] as String?;
        File? resolved;
        if (path != null && path.isNotEmpty) {
          final abs =
              p.isAbsolute(path) ? path : p.join(configRoot, 'scenarios', path);
          resolved = File(abs);
        } else if (id != null && id.isNotEmpty) {
          resolved = await resolveScenarioFile(id);
          if (resolved == null) {
            return _err('scenario "$id" not found in any source');
          }
        } else {
          return _err('scenario, path, or id required');
        }
        if (!await resolved.exists()) {
          return _err('scenario file not found: ${resolved.path}');
        }
        try {
          scenario = scenarioFromJsonString(await resolved.readAsString());
        } catch (e) {
          return _err('scenario load failed: $e');
        }
      }
      final dryRun = args['dryRun'] as bool? ?? false;
      final report = await engine.run(scenario, dryRun: dryRun);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': report.error == null,
              ...report.toJson(),
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.scenario.list',
    description:
        'List scenarios saved under `<configRoot>/scenarios/`. Each '
        'entry: `{id, path, title?}` (title is read from the JSON when '
        'parseable). Use to surface a picker UI or by an external LLM '
        'before calling `run`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final entries = <Map<String, dynamic>>[];
      final projectDir = activeProjectScenariosDir?.call();
      final sources = <({String dir, String source})>[
        if (projectDir != null) (dir: projectDir, source: 'project'),
        (dir: p.join(configRoot, 'scenarios'), source: 'user'),
        for (final d in (seedScenarioDirs?.call() ?? const <String>[]))
          (dir: d, source: 'seed'),
      ];
      for (final src in sources) {
        final dir = Directory(src.dir);
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          if (!entity.path.endsWith('.json')) continue;
          final id = p.basenameWithoutExtension(entity.path);
          String? title;
          String? description;
          try {
            final raw = await entity.readAsString();
            final j = jsonDecode(raw);
            if (j is Map) {
              title = j['title']?.toString();
              description = j['description']?.toString();
            }
          } catch (_) {
            /* swallow — corrupt file just shows as id */
          }
          entries.add(<String, dynamic>{
            'id': id,
            'source': src.source,
            'path': entity.path,
            if (title != null) 'title': title,
            if (description != null) 'description': description,
          });
        }
      }
      entries.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'count': entries.length,
              'entries': entries,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.scenario.read',
    description:
        'Read one scenario by id and return the raw JSON object + '
        'source + path. Atom for UI detail panels — host calls this '
        'after the user selects an item from `scenario.list`. UI '
        'composes scenario.read + scenario.preview to render the '
        'detail (counts / duration / timeline) without the list '
        'response carrying per-item detail.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'id': <String, dynamic>{
          'type': 'string',
          'description':
              'Scenario id (filename without `.json`). Resolved '
              'against the same source order as `list` / `run`.',
        },
      },
      'required': <String>['id'],
    },
    handler: (args) async {
      final id = args['id'] as String?;
      if (id == null || id.isEmpty) return _err('id required');
      final file = await resolveScenarioFile(id);
      if (file == null) return _err('scenario "$id" not found');
      String text;
      try {
        text = await file.readAsString();
      } catch (e) {
        return _err('read failed: $e');
      }
      Map<String, dynamic>? obj;
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) obj = decoded.cast<String, dynamic>();
      } catch (e) {
        return _err('parse failed: $e');
      }
      if (obj == null) return _err('scenario root is not an object');
      // Determine source by which directory contains it.
      final projectDir = activeProjectScenariosDir?.call();
      String source = 'user';
      if (projectDir != null && file.path.startsWith(projectDir)) {
        source = 'project';
      } else {
        final cfgDir = p.join(configRoot, 'scenarios');
        if (file.path.startsWith(cfgDir)) {
          source = 'user';
        } else {
          for (final d in (seedScenarioDirs?.call() ?? const <String>[])) {
            if (file.path.startsWith(d)) {
              source = 'seed';
              break;
            }
          }
        }
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              'id': id,
              'source': source,
              'path': file.path,
              'scenario': obj,
              'scenarioText': text,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.scenario.preview',
    description:
        'Compile a scenario object into the VbuTimeline shape '
        '(`{steps:[{label,durationMs,color}], tracks:[{label,'
        'regions:[{atMs,durationMs,label,color}]}], totalMs, '
        'prepareCount, stepCount}`). The response keys are designed '
        'to map 1:1 onto VbuTimeline DSL props via auto-merge, so '
        'the Compose page binding `{{steps}}` / `{{tracks}}` updates '
        'live whenever VbuJsonEditor emits `parsed`. Steps fall back '
        'to `tool` name when `label` is absent. `durationMs` = '
        '`settleMs` + max(overlay.stayMs). Colors cycle through a '
        'small palette by tool prefix so similar steps group '
        'visually.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'scenario': <String, dynamic>{
          'description':
              'Scenario object (or JSON string) to compile. Same '
              'shape as `scenario.run` accepts inline.',
        },
      },
    },
    handler: (args) async {
      final raw = args['scenario'];
      Map<String, dynamic>? obj;
      if (raw is Map) {
        obj = raw.cast<String, dynamic>();
      } else if (raw is String) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) obj = decoded.cast<String, dynamic>();
        } catch (_) {
          return _err('scenario JSON parse failed');
        }
      }
      if (obj == null) return _err('scenario object or JSON string required');
      Scenario scenario;
      try {
        scenario = Scenario.fromJson(obj);
      } catch (e) {
        return _err('scenario load failed: $e');
      }
      final preview = _compileTimeline(scenario);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(preview)),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.scenario.save',
    description:
        "Persist a scenario JSON to `<configRoot>/scenarios/<id>.json`. "
        'The id is taken from the scenario object (or `id` arg). '
        'Use to commit a scenario the user / LLM just authored so '
        '`scenario.run` can pick it up next time by id alone.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'scenario': <String, dynamic>{
          'description': 'Scenario object to save (must include `id`).',
        },
      },
      'required': <String>['scenario'],
    },
    handler: (args) async {
      final raw = args['scenario'];
      Map<String, dynamic>? m;
      if (raw is Map) {
        m = raw.cast<String, dynamic>();
      } else if (raw is String && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) m = decoded.cast<String, dynamic>();
        } catch (e) {
          return _err('scenario JSON parse failed: $e');
        }
      }
      if (m == null) return _err('scenario object or JSON string required');
      final id = m['id']?.toString();
      if (id == null || id.isEmpty) return _err('scenario.id required');
      // Save to active scene project's scenarios/ when one is open,
      // otherwise fall back to configRoot/scenarios/.
      final projectDir = activeProjectScenariosDir?.call();
      final dirPath = projectDir ?? p.join(configRoot, 'scenarios');
      final dir = Directory(dirPath);
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, '$id.json'));
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(m));
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              'id': id,
              'path': file.path,
            }),
          ),
        ],
      );
    },
  );
}

/// Palette cycled by step index when no per-step color override
/// exists. Mint / amber / coral / lilac — same warm hues the
/// Scene Builder chrome uses elsewhere so the timeline preview
/// reads as part of the same surface.
const _kStepPalette = <String>['#4ECDC4', '#F1C40F', '#E78A7A', '#B39DDB'];

/// Track palette — neutral steel + amber so overlay regions stand
/// out against the step blocks above.
const _kTrackPalette = <String>['#9AA3B2', '#F1C40F', '#4ECDC4'];

Map<String, dynamic> _compileTimeline(Scenario s) {
  final stepBlocks = <Map<String, dynamic>>[];
  final all = <Step>[...s.prepare, ...s.steps];
  for (var i = 0; i < all.length; i++) {
    final step = all[i];
    var dur = step.settleMs;
    for (final ov in step.overlays) {
      final stay = ov['stayMs'];
      if (stay is num && stay.toInt() > dur) dur = stay.toInt();
    }
    final isPrepare = i < s.prepare.length;
    stepBlocks.add(<String, dynamic>{
      'label':
          (step.label != null && step.label!.isNotEmpty)
              ? step.label
              : (step.tool.isNotEmpty
                  ? step.tool.split('.').last
                  : 'step ${i + 1}'),
      'durationMs': dur,
      'color':
          isPrepare
              ? '#5C6370'
              : _kStepPalette[(i - s.prepare.length) % _kStepPalette.length],
    });
  }
  // overlayTracks → tracks grouped by 'kind'. Each entry has
  // at/duration/kind/label/text/title shape — collapse to the
  // VbuTimeline region tuple.
  final byKind = <String, List<Map<String, dynamic>>>{};
  for (final o in s.overlayTracks) {
    final kind = (o['kind'] ?? 'overlay').toString();
    byKind.putIfAbsent(kind, () => <Map<String, dynamic>>[]).add(o);
  }
  final tracks = <Map<String, dynamic>>[];
  var palette = 0;
  byKind.forEach((kind, entries) {
    final regions = <Map<String, dynamic>>[];
    for (final e in entries) {
      final at = (e['at'] ?? e['atMs'] ?? 0);
      final duration = (e['duration'] ?? e['durationMs'] ?? 1000);
      regions.add(<String, dynamic>{
        'atMs': at is num ? at.toInt() : 0,
        'durationMs': duration is num ? duration.toInt() : 1000,
        'label': (e['label'] ?? e['text'] ?? e['title'] ?? kind).toString(),
        'color': _kTrackPalette[palette % _kTrackPalette.length],
      });
    }
    tracks.add(<String, dynamic>{'label': kind, 'regions': regions});
    palette++;
  });
  var totalMs = 0;
  for (final b in stepBlocks) {
    totalMs += (b['durationMs'] as int);
  }
  for (final t in tracks) {
    for (final r in (t['regions'] as List)) {
      final end = (r['atMs'] as int) + (r['durationMs'] as int);
      if (end > totalMs) totalMs = end;
    }
  }
  return <String, dynamic>{
    'ok': true,
    'steps': stepBlocks,
    'tracks': tracks,
    'totalMs': totalMs,
    'prepareCount': s.prepare.length,
    'stepCount': s.steps.length,
  };
}

mk.KernelToolResult _err(String msg) => mk.KernelToolResult(
  content: <mk.KernelContent>[
    mk.KernelTextContent(
      text: jsonEncode(<String, dynamic>{'ok': false, 'error': msg}),
    ),
  ],
);
