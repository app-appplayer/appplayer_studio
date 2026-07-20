/// `registerScenarioTools` — locks the `studio.scenario.*` MCP surface over
/// a real [ScenarioEngine] (real `RecorderService`/`EncoderService`/
/// `OverlayController`/`ChromeBridge`, wired the same way
/// `recorder_tools_test.dart` builds them — no screenshot slot, so no
/// frames are captured, only state/dispatch matters):
///
/// - `list` — merges `<configRoot>/scenarios/` (`source:'user'`) with the
///   injectable seed dirs (`source:'seed'`) and, when wired, the active
///   project's scenarios dir (`source:'project'`); sorted by id.
/// - `read` — resolves one scenario by id against the same source order
///   (project → user → seed) and returns the raw JSON + resolved source.
/// - `run` — accepts an inline `scenario` object/JSON string, a `path`, or
///   an `id` (same resolution order); dispatches each step's tool through
///   the SAME `boot.callTool` entry point production uses.
/// - `preview` — compiles a scenario into the VbuTimeline step/track shape
///   (no engine/IO involved — pure compilation).
/// - `save` — persists to the active project's scenarios dir when one is
///   open, else `<configRoot>/scenarios/<id>.json`.
///
/// All `run` scenarios in this suite pass `dryRun:true` or `record:false`
/// so `RecorderService.start`/`stop` never runs a real capture loop —
/// `studio.recorder.encode` (ffmpeg) is integration-only, as noted in
/// `recorder_tools_test.dart`, and is not reached by these tests.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/capture/overlay/overlay_controller.dart';
import 'package:appplayer_studio/src/base/capture/recorder/encoder_service.dart';
import 'package:appplayer_studio/src/base/capture/recorder/recorder_service.dart';
import 'package:appplayer_studio/src/base/capture/scenario/scenario_engine.dart';
import 'package:appplayer_studio/src/base/capture/scenario/scenario_tools.dart';
import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';

Map<String, dynamic> _callResult(mk.KernelToolResult r) {
  final text = (r.content.first as mk.KernelTextContent).text;
  return jsonDecode(text) as Map<String, dynamic>;
}

/// Builds a boot host + a real [ScenarioEngine] + a `test.echo` fake tool
/// (so scenario steps have something real to dispatch + observe), and
/// registers `studio.scenario.*` over an injectable configRoot / seed dirs /
/// active-project-dir. Mirrors `recorder_tools_test.dart`'s `_setup()`.
({
  mk.InProcessKernelServerHost boot,
  ScenarioEngine engine,
  Directory tmp,
  List<Map<String, dynamic>> echoCalls,
  void Function(String?) setSeedDir,
  void Function(String?) setProjectDir,
})
_setup() {
  final tmp = Directory.systemTemp.createTempSync('scenario_tools_test_');
  final boot = mk.InProcessKernelServerHost();
  final echoCalls = <Map<String, dynamic>>[];
  boot.addTool(
    name: 'test.echo',
    description: 'records the args it was called with',
    inputSchema: const <String, dynamic>{'type': 'object'},
    handler: (args) async {
      echoCalls.add(Map<String, dynamic>.from(args));
      return mk.KernelToolResult(
        content: <mk.KernelContent>[const mk.KernelTextContent(text: 'ok')],
      );
    },
  );
  final bridge = ChromeBridge(); // captureScreenshot = null
  final engine = ScenarioEngine(
    boot: boot,
    recorder: RecorderService(bridge: bridge, configRoot: tmp.path),
    encoder: EncoderService(),
    overlays: OverlayController(),
    chromeBridge: bridge,
  );
  String? seedDir;
  String? projectDir;
  registerScenarioTools(
    boot,
    engine: engine,
    configRoot: tmp.path,
    seedScenarioDirs: () => seedDir == null ? const <String>[] : [seedDir!],
    activeProjectScenariosDir: () => projectDir,
  );
  return (
    boot: boot,
    engine: engine,
    tmp: tmp,
    echoCalls: echoCalls,
    setSeedDir: (v) => seedDir = v,
    setProjectDir: (v) => projectDir = v,
  );
}

Map<String, dynamic> _scenarioJson({
  required String id,
  String? title,
  String? description,
  List<Map<String, dynamic>>? steps,
  bool record = false,
}) => <String, dynamic>{
  'id': id,
  if (title != null) 'title': title,
  if (description != null) 'description': description,
  'steps': steps ?? const <Map<String, dynamic>>[],
  'record': record,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('registration', () {
    test('all studio.scenario.* tools are registered', () {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final names = s.boot.toolDefinitions.map((t) => t.name).toSet();
      for (final expected in <String>[
        'studio.scenario.run',
        'studio.scenario.list',
        'studio.scenario.read',
        'studio.scenario.preview',
        'studio.scenario.save',
      ]) {
        expect(names, contains(expected), reason: expected);
      }
    });
  });

  group('list', () {
    test('empty configRoot (no scenarios/ dir) → count:0', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final out = _callResult(
        await s.boot.callTool('studio.scenario.list', const {}),
      );
      expect(out['count'], 0);
      expect(out['entries'], isEmpty);
    });

    test(
      'lists user scenarios sorted by id, title/description read from JSON',
      () async {
        final s = _setup();
        addTearDown(() => s.tmp.deleteSync(recursive: true));
        final dir = Directory(p.join(s.tmp.path, 'scenarios'))
          ..createSync(recursive: true);
        File(p.join(dir.path, 'zeta.json')).writeAsStringSync(
          jsonEncode(_scenarioJson(id: 'zeta', title: 'Zeta scenario')),
        );
        File(p.join(dir.path, 'alpha.json')).writeAsStringSync(
          jsonEncode(
            _scenarioJson(
              id: 'alpha',
              title: 'Alpha scenario',
              description: 'first one',
            ),
          ),
        );

        final out = _callResult(
          await s.boot.callTool('studio.scenario.list', const {}),
        );
        expect(out['count'], 2);
        final entries = (out['entries'] as List).cast<Map>();
        expect(entries[0]['id'], 'alpha', reason: 'sorted by id');
        expect(entries[0]['source'], 'user');
        expect(entries[0]['title'], 'Alpha scenario');
        expect(entries[0]['description'], 'first one');
        expect(entries[1]['id'], 'zeta');
      },
    );

    test('a corrupt scenario file still lists (id only, no title)', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final dir = Directory(p.join(s.tmp.path, 'scenarios'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'broken.json')).writeAsStringSync('{not json');

      final out = _callResult(
        await s.boot.callTool('studio.scenario.list', const {}),
      );
      expect(out['count'], 1);
      final entry = (out['entries'] as List).single as Map;
      expect(entry['id'], 'broken');
      expect(entry.containsKey('title'), isFalse);
    });

    test('merges seed dir scenarios with source:seed', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final seedDir = Directory.systemTemp.createTempSync('scenario_seed_');
      addTearDown(() => seedDir.deleteSync(recursive: true));
      File(p.join(seedDir.path, 'seeded.json')).writeAsStringSync(
        jsonEncode(_scenarioJson(id: 'seeded', title: 'Seeded')),
      );
      s.setSeedDir(seedDir.path);

      final out = _callResult(
        await s.boot.callTool('studio.scenario.list', const {}),
      );
      expect(out['count'], 1);
      final entry = (out['entries'] as List).single as Map;
      expect(entry['id'], 'seeded');
      expect(entry['source'], 'seed');
    });

    test('merges active project scenarios with source:project', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final projDir = Directory.systemTemp.createTempSync(
        'scenario_project_',
      );
      addTearDown(() => projDir.deleteSync(recursive: true));
      File(p.join(projDir.path, 'proj.json')).writeAsStringSync(
        jsonEncode(_scenarioJson(id: 'proj', title: 'Project scenario')),
      );
      s.setProjectDir(projDir.path);

      final out = _callResult(
        await s.boot.callTool('studio.scenario.list', const {}),
      );
      expect(out['count'], 1);
      final entry = (out['entries'] as List).single as Map;
      expect(entry['id'], 'proj');
      expect(entry['source'], 'project');
    });
  });

  group('read', () {
    test('missing id → error', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final out = _callResult(
        await s.boot.callTool('studio.scenario.read', const {}),
      );
      expect(out['ok'], isFalse);
      expect(out['error'], contains('id required'));
    });

    test('unknown id → not found error', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final out = _callResult(
        await s.boot.callTool('studio.scenario.read', const {
          'id': 'ghost',
        }),
      );
      expect(out['ok'], isFalse);
      expect(out['error'], contains('not found'));
    });

    test('reads a user scenario: ok:true, source:user, raw scenario object',
        () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final dir = Directory(p.join(s.tmp.path, 'scenarios'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'r1.json')).writeAsStringSync(
        jsonEncode(_scenarioJson(id: 'r1', title: 'Read me')),
      );

      final out = _callResult(
        await s.boot.callTool('studio.scenario.read', const {'id': 'r1'}),
      );
      expect(out['ok'], isTrue);
      expect(out['id'], 'r1');
      expect(out['source'], 'user');
      expect((out['scenario'] as Map)['title'], 'Read me');
      expect(out['scenarioText'], isA<String>());
    });

    test(
      'project scenarios resolve ahead of a same-id user scenario '
      '(project → user → seed precedence)',
      () async {
        final s = _setup();
        addTearDown(() => s.tmp.deleteSync(recursive: true));
        final userDir = Directory(p.join(s.tmp.path, 'scenarios'))
          ..createSync(recursive: true);
        File(p.join(userDir.path, 'dup.json')).writeAsStringSync(
          jsonEncode(_scenarioJson(id: 'dup', title: 'user version')),
        );
        final projDir = Directory.systemTemp.createTempSync(
          'scenario_project_precedence_',
        );
        addTearDown(() => projDir.deleteSync(recursive: true));
        File(p.join(projDir.path, 'dup.json')).writeAsStringSync(
          jsonEncode(_scenarioJson(id: 'dup', title: 'project version')),
        );
        s.setProjectDir(projDir.path);

        final out = _callResult(
          await s.boot.callTool('studio.scenario.read', const {'id': 'dup'}),
        );
        expect(out['source'], 'project');
        expect((out['scenario'] as Map)['title'], 'project version');
      },
    );
  });

  group('run — inline scenario', () {
    test('empty scenario (no prepare/steps/overlayTracks) → empty-scenario',
        () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final out = _callResult(
        await s.boot.callTool('studio.scenario.run', <String, dynamic>{
          'scenario': _scenarioJson(id: 'empty'),
        }),
      );
      expect(out['ok'], isFalse);
      expect(out['error'], 'empty-scenario');
      expect(out['stepsExecuted'], 0);
    });

    test(
      'dispatches each step tool through boot.callTool, in order, with args',
      () async {
        final s = _setup();
        addTearDown(() => s.tmp.deleteSync(recursive: true));
        final out = _callResult(
          await s.boot.callTool('studio.scenario.run', <String, dynamic>{
            'scenario': _scenarioJson(
              id: 'echo-run',
              steps: [
                {
                  'tool': 'test.echo',
                  'args': {'n': 1},
                  'settleMs': 0,
                },
                {
                  'tool': 'test.echo',
                  'args': {'n': 2},
                  'settleMs': 0,
                },
              ],
            ),
          }),
        );
        expect(out['ok'], isTrue);
        expect(out['stepsExecuted'], 2);
        expect(s.echoCalls.map((c) => c['n']), [1, 2]);
      },
    );

    test(
      'dryRun:true skips the recorder even when scenario.record:true '
      '(no recording/encoding in the report)',
      () async {
        final s = _setup();
        addTearDown(() => s.tmp.deleteSync(recursive: true));
        final out = _callResult(
          await s.boot.callTool('studio.scenario.run', <String, dynamic>{
            'scenario': _scenarioJson(
              id: 'dry',
              record: true,
              steps: [
                {'tool': 'test.echo', 'settleMs': 0},
              ],
            ),
            'dryRun': true,
          }),
        );
        expect(out['ok'], isTrue);
        expect(out['stepsExecuted'], 1);
        expect(out.containsKey('recording'), isFalse);
        expect(out.containsKey('encoding'), isFalse);
        expect(s.echoCalls, hasLength(1));
      },
    );

    test('a step whose tool throws is swallowed — the run carries on',
        () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      s.boot.addTool(
        name: 'test.boom',
        description: 'always throws',
        inputSchema: const <String, dynamic>{'type': 'object'},
        handler: (args) async => throw StateError('boom'),
      );
      final out = _callResult(
        await s.boot.callTool('studio.scenario.run', <String, dynamic>{
          'scenario': _scenarioJson(
            id: 'boom-run',
            steps: [
              {'tool': 'test.boom', 'settleMs': 0},
              {
                'tool': 'test.echo',
                'args': {'after': 'boom'},
                'settleMs': 0,
              },
            ],
          ),
        }),
      );
      expect(out['ok'], isTrue);
      expect(out['stepsExecuted'], 2);
      expect(s.echoCalls.single['after'], 'boom');
    });

    test('malformed inline JSON string → scenario JSON parse failed',
        () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final out = _callResult(
        await s.boot.callTool('studio.scenario.run', const {
          'scenario': 'not valid json{',
        }),
      );
      expect(out['ok'], isFalse);
      expect(out['error'], contains('scenario JSON parse failed'));
    });

    test('neither scenario, path, nor id → required error', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final out = _callResult(
        await s.boot.callTool('studio.scenario.run', const {}),
      );
      expect(out['ok'], isFalse);
      expect(out['error'], contains('scenario, path, or id required'));
    });
  });

  group('run — by path', () {
    test('relative path resolves against <configRoot>/scenarios/', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final dir = Directory(p.join(s.tmp.path, 'scenarios'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'byPath.json')).writeAsStringSync(
        jsonEncode(
          _scenarioJson(
            id: 'byPath',
            steps: [
              {'tool': 'test.echo', 'settleMs': 0},
            ],
          ),
        ),
      );
      final out = _callResult(
        await s.boot.callTool('studio.scenario.run', const {
          'path': 'byPath.json',
        }),
      );
      expect(out['ok'], isTrue);
      expect(out['stepsExecuted'], 1);
    });

    test('missing file at path → not found error', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final out = _callResult(
        await s.boot.callTool('studio.scenario.run', const {
          'path': 'ghost.json',
        }),
      );
      expect(out['ok'], isFalse);
      expect(out['error'], contains('scenario file not found'));
    });
  });

  group('run — by id', () {
    test('resolves via user dir', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final dir = Directory(p.join(s.tmp.path, 'scenarios'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'byId.json')).writeAsStringSync(
        jsonEncode(
          _scenarioJson(
            id: 'byId',
            steps: [
              {'tool': 'test.echo', 'settleMs': 0},
            ],
          ),
        ),
      );
      final out = _callResult(
        await s.boot.callTool('studio.scenario.run', const {'id': 'byId'}),
      );
      expect(out['ok'], isTrue);
      expect(out['stepsExecuted'], 1);
    });

    test('unknown id → not found in any source', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final out = _callResult(
        await s.boot.callTool('studio.scenario.run', const {'id': 'ghost'}),
      );
      expect(out['ok'], isFalse);
      expect(out['error'], contains('not found in any source'));
    });

    test('project scenario takes precedence over a same-id user scenario',
        () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final userDir = Directory(p.join(s.tmp.path, 'scenarios'))
        ..createSync(recursive: true);
      File(p.join(userDir.path, 'dup.json')).writeAsStringSync(
        jsonEncode(
          _scenarioJson(
            id: 'dup',
            steps: [
              {
                'tool': 'test.echo',
                'args': {'from': 'user'},
                'settleMs': 0,
              },
            ],
          ),
        ),
      );
      final projDir = Directory.systemTemp.createTempSync(
        'scenario_run_project_precedence_',
      );
      addTearDown(() => projDir.deleteSync(recursive: true));
      File(p.join(projDir.path, 'dup.json')).writeAsStringSync(
        jsonEncode(
          _scenarioJson(
            id: 'dup',
            steps: [
              {
                'tool': 'test.echo',
                'args': {'from': 'project'},
                'settleMs': 0,
              },
            ],
          ),
        ),
      );
      s.setProjectDir(projDir.path);

      await s.boot.callTool('studio.scenario.run', const {'id': 'dup'});
      expect(s.echoCalls.single['from'], 'project');
    });
  });

  group('preview', () {
    test('missing scenario → error', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final out = _callResult(
        await s.boot.callTool('studio.scenario.preview', const {}),
      );
      expect(out['ok'], isFalse);
    });

    test(
      'compiles steps (durationMs = settleMs, or overlay stayMs when '
      'larger) and groups overlayTracks by kind',
      () async {
        final s = _setup();
        addTearDown(() => s.tmp.deleteSync(recursive: true));
        final out = _callResult(
          await s.boot.callTool('studio.scenario.preview', <String, dynamic>{
            'scenario': <String, dynamic>{
              'id': 'preview-1',
              'title': 'Preview',
              'prepare': [
                {'tool': 'prep.tool', 'settleMs': 100},
              ],
              'steps': [
                {
                  'tool': 'a.b.click',
                  'settleMs': 200,
                  'overlays': [
                    {'stayMs': 500},
                  ],
                },
                {'tool': '', 'label': 'pure pause', 'settleMs': 300},
              ],
              'overlayTracks': [
                {
                  'at': 0,
                  'duration': 1000,
                  'kind': 'watermark',
                  'label': 'wm',
                },
                {
                  'at': 2000,
                  'duration': 500,
                  'kind': 'watermark',
                  'label': 'wm2',
                },
                {
                  'at': 100,
                  'duration': 400,
                  'kind': 'caption',
                  'text': 'hi',
                },
              ],
            },
          }),
        );
        expect(out['ok'], isTrue);
        expect(out['prepareCount'], 1);
        expect(out['stepCount'], 2);
        final steps = (out['steps'] as List).cast<Map>();
        expect(steps, hasLength(3)); // prepare + 2 steps
        expect(steps[0]['durationMs'], 100); // prepare uses settleMs
        expect(steps[0]['color'], '#5C6370'); // prepare palette
        // Step 1 (index 0 in `steps` list, index 1 overall): settleMs 200
        // but overlay stayMs 500 wins.
        expect(steps[1]['durationMs'], 500);
        expect(steps[1]['label'], 'click'); // tool 'a.b.click' → last segment
        expect(steps[2]['label'], 'pure pause'); // explicit label used
        expect(steps[2]['durationMs'], 300);

        final tracks = (out['tracks'] as List).cast<Map>();
        final byLabel = {for (final t in tracks) t['label']: t};
        expect(byLabel.keys.toSet(), {'watermark', 'caption'});
        final wmRegions = (byLabel['watermark']!['regions'] as List).cast<Map>();
        expect(wmRegions, hasLength(2));
        // totalMs = max(step total, furthest track region end).
        // steps total = 100 + 500 + 300 = 900; watermark2 ends at 2500.
        expect(out['totalMs'], 2500);
      },
    );

    test('accepts a JSON string too', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final out = _callResult(
        await s.boot.callTool('studio.scenario.preview', <String, dynamic>{
          'scenario': jsonEncode(_scenarioJson(id: 'str-preview')),
        }),
      );
      expect(out['ok'], isTrue);
    });
  });

  group('save', () {
    test('requires a scenario with an id', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final noScenario = _callResult(
        await s.boot.callTool('studio.scenario.save', const {}),
      );
      expect(noScenario['ok'], isFalse);

      final noId = _callResult(
        await s.boot.callTool('studio.scenario.save', <String, dynamic>{
          'scenario': <String, dynamic>{'title': 'no id'},
        }),
      );
      expect(noId['ok'], isFalse);
      expect(noId['error'], contains('scenario.id required'));
    });

    test('persists to <configRoot>/scenarios/<id>.json (no active project)',
        () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final out = _callResult(
        await s.boot.callTool('studio.scenario.save', <String, dynamic>{
          'scenario': _scenarioJson(id: 'saved-1', title: 'Saved one'),
        }),
      );
      expect(out['ok'], isTrue);
      expect(out['id'], 'saved-1');
      final expectedPath = p.join(s.tmp.path, 'scenarios', 'saved-1.json');
      expect(out['path'], expectedPath);
      final onDisk = File(expectedPath).readAsStringSync();
      expect((jsonDecode(onDisk) as Map)['title'], 'Saved one');
    });

    test('persists to the active project scenarios dir when one is open',
        () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final projDir = Directory.systemTemp.createTempSync(
        'scenario_save_project_',
      );
      addTearDown(() => projDir.deleteSync(recursive: true));
      s.setProjectDir(projDir.path);

      final out = _callResult(
        await s.boot.callTool('studio.scenario.save', <String, dynamic>{
          'scenario': _scenarioJson(id: 'proj-saved'),
        }),
      );
      expect(out['ok'], isTrue);
      final expectedPath = p.join(projDir.path, 'proj-saved.json');
      expect(out['path'], expectedPath);
      expect(File(expectedPath).existsSync(), isTrue);
      // Did NOT also land under configRoot/scenarios/.
      expect(
        File(p.join(s.tmp.path, 'scenarios', 'proj-saved.json')).existsSync(),
        isFalse,
      );
    });

    test('accepts a JSON string scenario too', () async {
      final s = _setup();
      addTearDown(() => s.tmp.deleteSync(recursive: true));
      final out = _callResult(
        await s.boot.callTool('studio.scenario.save', <String, dynamic>{
          'scenario': jsonEncode(_scenarioJson(id: 'str-saved')),
        }),
      );
      expect(out['ok'], isTrue);
      expect(out['id'], 'str-saved');
    });
  });
}
