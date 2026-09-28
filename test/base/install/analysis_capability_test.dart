/// `analysis.*` capability recipe over the standard in-memory engine
/// (`mcp_analysis` 0.2.0). Drives every verb the way a bundle would — by
/// verb name with JSON arguments — so a port operation without a verb, or a
/// verb whose argument shape drifted from the port, fails here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/install/capability_recipes/capability_recipes.dart'
    show
        CapabilityTool,
        CapabilityToolError,
        analysisCapabilityTools,
        standardAnalysisPort;

CapabilityTool _byVerb(List<CapabilityTool> tools, String verb) =>
    tools.firstWhere((t) => t.verb == verb);

/// 64 samples of a 4 Hz tone at 32 Hz: one clear spectral line.
Map<String, dynamic> _tone({int seed = 1, double frequency = 4}) =>
    <String, dynamic>{
      'sourceType': 'synthetic',
      'query':
          '{"samples":64,"sampleRate":32,"seed":$seed,'
          '"components":[{"kind":"sine","amplitude":1,'
          '"frequency":$frequency}]}',
    };

/// `fft → peak_detect`: the second step reads the spectrum, not the signal.
Map<String, dynamic> _chainedSpec(String specId) => <String, dynamic>{
  'specId': specId,
  'version': '1.0.0',
  'inputSources': <Map<String, dynamic>>[_tone()],
  'analysisSteps': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'spectrum',
      'function': 'fft',
      'parameters': <String, dynamic>{'column': 'value', 'sampleRate': 32},
    },
    <String, dynamic>{
      'id': 'peaks',
      'function': 'peak_detect',
      'parameters': <String, dynamic>{'column': 'value', 'minHeight': 0.05},
      'input': <String, dynamic>{
        'from': 'spectrum',
        'field': 'magnitudes',
        'indexField': 'frequencies',
      },
    },
  ],
  'outputs': <Map<String, dynamic>>[
    <String, dynamic>{'from': 'peaks', 'type': 'summary', 'name': 'peaks'},
  ],
  'metadata': <String, dynamic>{'description': 'chained'},
};

/// Two channels measured alongside each other: the second source joins
/// onto the first as a column (`sensor_b`), and one step reads both.
Map<String, dynamic> _joinSpec(String specId) => <String, dynamic>{
  'specId': specId,
  'version': '1.0.0',
  'inputSources': <Map<String, dynamic>>[
    _tone(),
    <String, dynamic>{
      ..._tone(seed: 2, frequency: 8),
      'columnAliases': <String, String>{'value': 'sensor_b'},
      'merge': 'join',
    },
  ],
  'analysisSteps': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'xcorr',
      'function': 'cross_correlation',
      'parameters': <String, dynamic>{
        'columns': <String>['value', 'sensor_b'],
        'maxLag': 8,
      },
    },
  ],
  'outputs': <Map<String, dynamic>>[
    <String, dynamic>{'from': 'xcorr', 'type': 'summary', 'name': 'xcorr'},
  ],
  'metadata': <String, dynamic>{'description': 'join'},
};

void main() {
  late List<CapabilityTool> tools;
  setUp(() => tools = analysisCapabilityTools(standardAnalysisPort()));

  Future<Map<String, dynamic>> call(
    String verb, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async => (await _byVerb(tools, verb).invoke(args)) as Map<String, dynamic>;

  test('surface — every port operation has a verb', () {
    expect(
      tools.map((t) => t.verb).toSet(),
      equals(<String>{
        'list_specs',
        'run',
        'get_job',
        'list_jobs',
        'cancel_job',
        'get_artifacts',
        'create_spec',
        'update_spec',
        'delete_spec',
        'list_functions',
        'evaluate_alert',
      }),
    );
  });

  test('list_functions — catalog with declared result fields', () async {
    final all = await call('list_functions');
    final functions = (all['functions'] as List).cast<Map<String, dynamic>>();
    expect(functions.length, greaterThanOrEqualTo(35));
    final fft = functions.singleWhere((f) => f['functionName'] == 'fft');
    expect(
      (fft['results'] as Map).keys,
      containsAll(<String>['frequencies', 'magnitudes']),
    );
    final searched = await call('list_functions', {'search': 'peak'});
    expect(
      (searched['functions'] as List).map((f) => f['functionName']),
      contains('peak_detect'),
    );
  });

  test(
    'chained spec: create → run → get_job → get_artifacts → list_jobs',
    () async {
      final created = await call('create_spec', {
        'spec': _chainedSpec('chain'),
      });
      expect(created['specId'], 'chain');
      expect((await call('list_specs'))['specs'], contains('chain'));

      final run = await call('run', {'specId': 'chain'});
      final jobId = run['jobId'] as String;
      final job = await call('get_job', {'jobId': jobId});
      expect(job['found'], isTrue);
      expect(job['status'], 'completed');

      final artifacts =
          (await call('get_artifacts', {'jobId': jobId}))['artifacts'] as List;
      expect(artifacts, hasLength(1));
      final summary = artifacts.single as Map<String, dynamic>;
      expect(summary['type'], 'summary');
      expect(summary['text'], contains('indices'));

      final listed =
          (await call('list_jobs', {'specId': 'chain'}))['jobs'] as List;
      expect(listed.map((j) => j['jobId']), contains(jobId));
      final completed =
          (await call('list_jobs', {'status': 'completed'}))['jobs'] as List;
      expect(completed.map((j) => j['jobId']), contains(jobId));
      final running =
          (await call('list_jobs', {'status': 'running'}))['jobs'] as List;
      expect(running, isEmpty);
    },
  );

  test('two channels joined: one step reads both columns', () async {
    await call('create_spec', {'spec': _joinSpec('join')});
    final run = await call('run', {'specId': 'join'});
    final job = await call('get_job', {'jobId': run['jobId']});
    expect(job['status'], 'completed', reason: 'join must resolve sensor_b');
    final artifacts =
        (await call('get_artifacts', {'jobId': run['jobId']}))['artifacts']
            as List;
    expect(artifacts, hasLength(1));
    expect((artifacts.single as Map)['text'], contains('correlations'));
  });

  test('0.2.0 rejects an output that names no step', () async {
    final spec = _chainedSpec('bad-output');
    spec['outputs'] = <Map<String, dynamic>>[
      <String, dynamic>{'from': 'nowhere', 'type': 'summary', 'name': 'x'},
    ];
    await expectLater(
      call('create_spec', {'spec': spec}),
      throwsA(
        isA<CapabilityToolError>()
            .having((e) => e.code, 'code', 'analysis.spec.invalid')
            .having(
              (e) => e.message,
              'message',
              contains('unresolved_output_source'),
            ),
      ),
    );
  });

  test('0.2.0 rejects two steps on one function without ids', () async {
    final spec = _chainedSpec('dup');
    spec['analysisSteps'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'function': 'fft',
        'parameters': <String, dynamic>{'column': 'value', 'sampleRate': 32},
      },
      <String, dynamic>{
        'function': 'fft',
        'parameters': <String, dynamic>{'column': 'value', 'sampleRate': 32},
      },
    ];
    spec['outputs'] = <Map<String, dynamic>>[
      <String, dynamic>{'from': 'fft', 'type': 'summary', 'name': 'x'},
    ];
    await expectLater(
      call('create_spec', {'spec': spec}),
      throwsA(
        isA<CapabilityToolError>()
            .having((e) => e.code, 'code', 'analysis.spec.invalid')
            .having(
              (e) => e.message,
              'message',
              contains('duplicate_step_key'),
            ),
      ),
    );
  });

  test('delete_spec removes the spec from list_specs', () async {
    await call('create_spec', {'spec': _chainedSpec('gone')});
    expect((await call('list_specs'))['specs'], contains('gone'));
    expect(await call('delete_spec', {'specId': 'gone'}), {
      'specId': 'gone',
      'deleted': true,
    });
    expect((await call('list_specs'))['specs'], isNot(contains('gone')));
  });

  test('cancel_job on a finished job surfaces the refusal', () async {
    await call('create_spec', {'spec': _chainedSpec('cancel')});
    final run = await call('run', {'specId': 'cancel'});
    // A batch job on the in-memory engine completes before `run` returns,
    // so the only reachable cancel is a refused one: the state machine must
    // surface its refusal, not swallow it.
    await expectLater(
      call('cancel_job', {'jobId': run['jobId']}),
      throwsA(
        isA<CapabilityToolError>().having(
          (e) => e.code,
          'code',
          'analysis.job.invalid_transition',
        ),
      ),
    );
  });

  test('bad input is rejected before it reaches the port', () async {
    expect(
      () => call('list_jobs', {'status': 'done'}),
      throwsA(isA<CapabilityToolError>()),
    );
    expect(
      () => call('cancel_job', const <String, dynamic>{}),
      throwsA(isA<CapabilityToolError>()),
    );
    expect(
      () => call('delete_spec', {'specId': ''}),
      throwsA(isA<CapabilityToolError>()),
    );
  });
}
