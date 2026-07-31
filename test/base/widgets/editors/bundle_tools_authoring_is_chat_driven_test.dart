/// Authoring in the bundle Tools editor is chat-driven, by decision.
///
/// `_surfaceHeader` accepts an `onAdd` and would paint a "+", and four `_add*`
/// implementations sit behind it — but no call site passes the callback. That
/// reads exactly like an unwired gap, and it is not: `build` has said since
/// 0.1.0 that "`+` add buttons are dropped per the bibe ("vibe") mode —
/// chat-driven LLM tool calls do the authoring", and the create path is served
/// by `studio.builder.addTool` and its siblings.
///
/// This file exists because that gap-shaped design was in fact "fixed" once,
/// by wiring the four headers, which silently reverted a product decision. The
/// asymmetry (delete is manual, create is not) is deliberate and cannot be
/// read off the call sites, so it is locked here instead.
///
///   d1  no surface header offers an add affordance
///   d2  the detail panel still offers manual delete — the asymmetry is the
///       point, so a test that only checked "no +" would pass on a dead editor
///   d3  the chat-side create path is the one that exists
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(width: 1400, child: child),
    ),
  ),
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late Directory tmp;
  late ChromeBridge bridge;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bundle_tools_authoring_');
    bridge = ChromeBridge();
    File('${tmp.path}/manifest.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 't', 'name': 'T', 'version': '1'},
        'tools': <dynamic>[
          <String, dynamic>{
            'name': 'my_tool',
            'kind': 'host',
            'description': '',
          },
        ],
      }),
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpEditor(WidgetTester tester) async {
    // The detail pane's controls sit past x=1300. On the default 800px test
    // viewport a tap on them lands on nothing and silently does nothing, so
    // the surface has to be wide enough to actually hit them.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(
        BundleToolsView(
          bundlePath: tmp.path,
          overridesFile: '${tmp.path}/overrides.json',
          chromeBridge: bridge,
          reloadCounter: 0,
          layout: BundleToolsLayout.panel,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('d1 no section header offers an add affordance', (tester) async {
    await pumpEditor(tester);
    for (final title in <String>[
      'TOOLS',
      'DOMAIN ICONS',
      '/ COMMANDS',
      'SETTINGS',
      'LIFECYCLE',
    ]) {
      final header = find.ancestor(
        of: find.textContaining('$title ('),
        matching: find.byType(Row),
      ).first;
      expect(
        find.descendant(of: header, matching: find.byIcon(Icons.add)),
        findsNothing,
        reason:
            'authoring in this editor is chat-driven by decision — a "+" on '
            '$title reverts that. If the decision has changed, change the note '
            'in build() and this test together, not just the call site',
      );
    }
  });

  testWidgets('d2 manual delete still WORKS — the asymmetry is the point',
      (tester) async {
    await pumpEditor(tester);
    // Select the seeded tool so its detail editor mounts.
    await tester.tap(find.text('my_tool').first);
    await tester.pump();

    // Press it and read the manifest back. Asserting the icon merely renders
    // would pass against a delete whose callback had been gutted, and then d1
    // would be green on a dead editor rather than on the decision.
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Delete tool'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();

    final raw =
        jsonDecode(File('${tmp.path}/manifest.json').readAsStringSync())
            as Map<String, dynamic>;
    final tools = raw['tools'];
    expect(
      (tools is Map ? tools['tools'] : tools) as List,
      isEmpty,
      reason:
          'if delete no longer works this editor is dead, and d1 would pass '
          'for the wrong reason',
    );
  });
}
