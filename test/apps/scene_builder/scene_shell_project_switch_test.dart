/// Opening a scene project while the Scenarios mode is showing must re-list
/// that project's scenarios. The mode views load once in `initState`, so the
/// shell rebuilds the active view when the project changes.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart'
    show ChatTurn, ChromeBridge, VibeChatController;
// ignore: depend_on_referenced_packages
import 'package:appplayer_studio/src/apps/scene_builder/feat/scene_shell.dart';

void main() {
  late ChromeBridge bridge;
  late Map<String, List<String>> scenariosByProject;
  var project = '';
  var listCalls = 0;

  setUp(() {
    bridge = ChromeBridge();
    project = '';
    listCalls = 0;
    scenariosByProject = <String, List<String>>{
      '': <String>[],
      '/p/one': <String>['one_a', 'one_b'],
      '/p/two': <String>['two_a'],
    };
    bridge.callHostTool = (tool, params) async {
      if (tool == 'studio.scenario.list') {
        listCalls++;
        return <String, dynamic>{
          'content': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'text': jsonEncode(<String, dynamic>{
                'entries': <Map<String, dynamic>>[
                  for (final id in scenariosByProject[project]!)
                    <String, dynamic>{
                      'id': id,
                      'title': id,
                      'path': '$project/scenarios/$id.json',
                    },
                ],
              }),
            },
          ],
        };
      }
      return <String, dynamic>{'ok': true};
    };
  });

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SceneShell(
            bundlePath: '/tmp/scene_switch_test_bundle',
            chromeBridge: bridge,
            chat: VibeChatController(
              send: (_) async => ChatTurn(role: 'assistant', text: 'ok'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('opening a project re-lists its scenarios', (tester) async {
    await pumpShell(tester);
    expect(find.text('one_a'), findsNothing);

    project = '/p/one';
    await bridge.openProjectInActive!('/p/one');
    await tester.pumpAndSettle();
    expect(find.text('one_a'), findsWidgets);
    expect(find.text('one_b'), findsWidgets);

    project = '/p/two';
    await bridge.openProjectInActive!('/p/two');
    await tester.pumpAndSettle();
    expect(find.text('one_a'), findsNothing);
    expect(find.text('two_a'), findsWidgets);
  });

  testWidgets('re-opening the same project does not reload the list', (
    tester,
  ) async {
    await pumpShell(tester);
    project = '/p/one';
    await bridge.openProjectInActive!('/p/one');
    await tester.pumpAndSettle();
    final after = listCalls;

    await bridge.openProjectInActive!('/p/one');
    await tester.pumpAndSettle();
    expect(listCalls, after);
  });
}
