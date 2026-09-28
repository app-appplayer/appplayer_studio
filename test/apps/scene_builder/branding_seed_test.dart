/// Branding shows the built-in Scene Builder theme. The view resolved its
/// bundle only through `studio.bundle.list`, which lists user installs and
/// leaves the built-in seeds out — so Branding always failed with
/// "scene_builder bundle not registered". It now falls back to the host's
/// seed set.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/apps/scene_builder/feat/branding_view.dart';
import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _text(Object body) => <String, dynamic>{
  'content': <Map<String, dynamic>>[
    {'type': 'text', 'text': jsonEncode(body)},
  ],
};

void main() {
  test('sceneBuilderSeedPath picks the scene_builder seed', () {
    expect(
      sceneBuilderSeedPath(<String>[
        '/a/app_builder.mbd',
        '/a/scene_builder.mbd',
      ]),
      '/a/scene_builder.mbd',
    );
    expect(sceneBuilderSeedPath(<String>['/a/ops.mbd']), isNull);
  });

  testWidgets('empty bundle list → the seed theme renders', (tester) async {
    final seed = Directory('seed/scene_builder.mbd').absolute.path;
    final theme = File('$seed/branding/theme.json').readAsStringSync();
    final reads = <String>[];
    final bridge = ChromeBridge();
    bridge.builtInSeedMbdPaths.add(seed);
    bridge.callHostTool = (tool, args) async {
      if (tool == 'studio.bundle.list') {
        return _text(<String, dynamic>{'bundles': <Object>[]});
      }
      if (tool == 'studio.bundle.read_file') {
        reads.add('${args['mbdPath']}/${args['relPath']}');
        return _text(<String, dynamic>{'ok': true, 'content': theme});
      }
      return _text(<String, dynamic>{'ok': false, 'error': 'unexpected $tool'});
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrandingView(bundlePath: '/unused', chromeBridge: bridge),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reads, <String>['$seed/branding/theme.json']);
    expect(find.textContaining('not registered'), findsNothing);
    expect(find.text('AppPlayer Studio'), findsWidgets);
  });
}
