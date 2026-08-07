// Measurement, not a gate.
//
// `dsl_workspace_view` mounts every document with `validateSchema: false`.
// The comment there blames host-registered `Vbu*` widgets being absent from
// the core schema. The runtime now masks host extensions before validating
// (`_maskExtensions` consults `engine.widgetRegistry`), so the stated reason
// is conditional on WHEN the host registers: the workspace registers AFTER
// `initialize`, which is after validation has already run.
//
// This surveys the real bundle corpus under both orders and prints how many
// documents the schema gate would reject. Asserts nothing about the counts —
// a red build here would mean the corpus disagrees with the schema, which is
// the thing being measured.

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart' as base;
import 'package:appplayer_studio/runtime.dart' as studio;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('survey: runtime schema gate over the real bundle corpus',
      (tester) async {
    final root = _findCorpusRoot();
    if (root == null) {
      // A standalone clone has no workspace tree to survey.
      return;
    }

    final files = Directory(root)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .where((f) => p.basename(f.parent.path) == 'ui')
        // `.history/` holds previous writes of the same document.
        .where((f) => !f.path.contains('/.history/'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    // Harness probes: documents whose verdict is known before the run. If
    // `_reject` clears the gate the survey is measuring nothing, and a
    // `rejected: 0` over the corpus would be a false all-clear.
    final probes = <String, Map<String, dynamic>>{
      '_probe_accept': {
        'type': 'page',
        'content': {'type': 'text', 'content': 'ok'},
      },
      '_probe_unknown_type': {
        'type': 'page',
        'content': {'type': 'no_such_widget_type'},
      },
      '_probe_missing_required': {
        'type': 'page',
        'content': {'type': 'text'},
      },
      '_probe_wrong_scalar_type': {
        'type': 'page',
        'content': {'type': 'text', 'content': 42},
      },
      '_probe_children_not_a_list': {
        'type': 'page',
        'content': {'type': 'linear', 'children': 'not-a-list'},
      },
      '_probe_bad_enum': {
        'type': 'page',
        'content': {
          'type': 'button',
          'label': 'x',
          'variant': 'fancy',
        },
      },
      '_probe_nested_unknown_type': {
        'type': 'page',
        'content': {
          'type': 'linear',
          'children': [
            {'type': 'no_such_widget_type'},
          ],
        },
      },
      '_probe_vbu': {
        'type': 'page',
        'content': {'type': 'VbuHeroPanel'},
      },
    };

    for (final registerFirst in const [false, true]) {
      var docs = 0, rejected = 0, otherError = 0;
      final samples = <String>[];
      final probeVerdicts = <String, String>{};

      for (final entry in [
        ...probes.entries.map((e) => MapEntry(e.key, e.value)),
        ...files.map((f) => MapEntry(f.path, null)),
      ]) {
        final isProbe = probes.containsKey(entry.key);
        Object? doc = entry.value;
        if (!isProbe) {
          try {
            doc = jsonDecode(File(entry.key).readAsStringSync());
          } catch (_) {
            continue;
          }
        }
        if (doc is! Map<String, dynamic>) continue;
        if (!isProbe) docs++;

        final runtime = studio.MCPUIRuntime();
        if (registerFirst) {
          base.registerToolWidgets(runtime);
          base.registerVbuWidgets(runtime);
        }
        // The catch has to live INSIDE `runAsync`. `initialize` throws from
        // the async zone `runAsync` sets up, so a try/catch around the
        // `await` never sees it — the framework does, and the survey reads
        // every rejection as an acceptance. That is what the first run of
        // this file reported.
        final failure = await tester.runAsync<Object?>(() async {
          try {
            await runtime.initialize(
              doc as Map<String, dynamic>,
              // `application` documents refuse to initialize without one.
              // It runs after the schema gate, so an empty page keeps the
              // engine from failing for a reason this survey is not asking
              // about.
              pageLoader: (_) async => <String, dynamic>{
                'type': 'page',
                'content': {'type': 'box'},
              },
            );
            return null;
          } catch (e) {
            return e;
          }
        });

        final isSchemaFailure = failure is StateError &&
            failure.message.contains('schema validation failed');
        if (failure == null) {
          if (isProbe) probeVerdicts[entry.key] = 'accepted';
        } else if (isSchemaFailure) {
          if (isProbe) {
            probeVerdicts[entry.key] = 'rejected';
          } else {
            rejected++;
            if (samples.length < 10) {
              samples.add('${p.relative(entry.key, from: root)}\n'
                  '      ${failure.message.split('\n').skip(1).take(3).join('\n      ')}');
            }
          }
        } else {
          // Engine wiring failures are past the schema gate — this survey
          // only asks whether the document cleared validation.
          if (isProbe) probeVerdicts[entry.key] = 'past-gate error';
          otherError++;
        }
        try {
          await tester.runAsync(() => runtime.destroy());
        } catch (_) {}
      }

      // ignore: avoid_print
      print('runtime schema gate — registerFirst: $registerFirst · '
          'docs: $docs · rejected: $rejected · past-gate errors: $otherError');
      // ignore: avoid_print
      print('  probes: $probeVerdicts');
      for (final s in samples) {
        // ignore: avoid_print
        print('  $s');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}

/// The bundle corpus lives beside the studio trees
/// (`appplayer_vibe_studio/workspace`), not inside `standard/`.
String? _findCorpusRoot() {
  var dir = Directory.current.path;
  for (var i = 0; i < 6; i++) {
    final candidate = p.join(dir, 'workspace');
    if (Directory(p.join(dir, 'debug')).existsSync() &&
        Directory(candidate).existsSync()) {
      return candidate;
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return null;
}
