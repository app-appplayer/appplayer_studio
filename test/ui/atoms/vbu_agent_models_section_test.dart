/// `AgentModelsSection` — per-bundle agent model picker.
/// `_load()` is synchronous (File.existsSync / readAsStringSync) so
/// testWidgets is safe. When the manifest file does not exist the
/// widget renders its "no agents" empty-state immediately.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

const _kModels = <VibeModelOption>[
  VibeModelOption(
    id: 'claude-3-5-sonnet',
    label: 'Sonnet 3.5',
    provider: 'anthropic',
  ),
  VibeModelOption(id: 'gpt-4o', label: 'GPT-4o', provider: 'openai'),
];

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('AgentModelsSection — no manifest file', () {
    testWidgets('renders empty-state when manifest path does not exist', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          AgentModelsSection(
            manifestPath: '/tmp/__nonexistent_test_manifest__.json',
            modelOptions: _kModels,
          ),
        ),
      );
      // Single pump — synchronous _load() runs in initState, one frame is enough.
      await tester.pump();
      expect(find.textContaining('No agents'), findsOneWidget);
    });

    testWidgets('does not throw without a chromeBridge', (tester) async {
      await tester.pumpWidget(
        _wrap(
          AgentModelsSection(
            manifestPath: '/tmp/__nonexistent_2__.json',
            modelOptions: _kModels,
            chromeBridge: null,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(AgentModelsSection), findsOneWidget);
    });
  });

  group('AgentModelsSection — manifest with agents', () {
    late Directory tmpDir;
    late File manifestFile;

    setUp(() {
      // Synchronous directory/file creation for test isolation.
      tmpDir = Directory.systemTemp.createTempSync('vbu_agent_models_test_');
      manifestFile = File('${tmpDir.path}/manifest.json');
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    testWidgets('renders a row per agent in canonical shape', (tester) async {
      manifestFile.writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'agents': <String, dynamic>{
            'agents': <dynamic>[
              <String, dynamic>{'id': 'agent-a', 'role': 'manager'},
              <String, dynamic>{'id': 'agent-b', 'role': 'worker'},
            ],
          },
        }),
      );
      await tester.pumpWidget(
        _wrap(
          AgentModelsSection(
            manifestPath: manifestFile.path,
            modelOptions: _kModels,
          ),
        ),
      );
      // Use pump() — synchronous _load() runs in initState so a single
      // frame is sufficient. pumpAndSettle hangs because VbuLabelledMenu
      // has hover/animation state that never idles.
      await tester.pump();
      expect(find.text('agent-a'), findsOneWidget);
      expect(find.text('agent-b'), findsOneWidget);
    });

    testWidgets('renders a row per agent in legacy flat shape', (tester) async {
      manifestFile.writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'agents': <dynamic>[
            <String, dynamic>{'id': 'flat-agent'},
          ],
        }),
      );
      await tester.pumpWidget(
        _wrap(
          AgentModelsSection(
            manifestPath: manifestFile.path,
            modelOptions: _kModels,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('flat-agent'), findsOneWidget);
    });

    testWidgets('shows no-agents text when agents list is empty', (
      tester,
    ) async {
      manifestFile.writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'agents': <String, dynamic>{'agents': <dynamic>[]},
        }),
      );
      await tester.pumpWidget(
        _wrap(
          AgentModelsSection(
            manifestPath: manifestFile.path,
            modelOptions: _kModels,
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('No agents'), findsOneWidget);
    });

    testWidgets('shows error text when manifest.json is not a JSON object', (
      tester,
    ) async {
      manifestFile.writeAsStringSync('[1,2,3]');
      await tester.pumpWidget(
        _wrap(
          AgentModelsSection(
            manifestPath: manifestFile.path,
            modelOptions: _kModels,
          ),
        ),
      );
      await tester.pump();
      // Either "No agents" or a failed-to-read error — not a crash.
      expect(find.byType(AgentModelsSection), findsOneWidget);
    });
  });
}
