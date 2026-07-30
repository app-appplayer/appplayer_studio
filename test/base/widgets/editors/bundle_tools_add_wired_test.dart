/// The bundle Tools editor let you DELETE a tool, a domain icon, a slash
/// command and a settings section, but not create one. `_surfaceHeader` was
/// written to take an `onAdd` and paint a "+", and every one of its call sites
/// left that argument off, so the button never rendered and the four `_add*`
/// implementations behind it were unreachable. Deleting the last tool left the
/// editor with no way back except the chat.
///
/// These lock the wiring, not the appearance:
///
///   a1  each section header exposes an add affordance
///   a2  pressing TOOLS "+" writes a new tool into manifest.json
///   a3  pressing "/ COMMANDS" "+" writes a new slash command
///   a4  pressing SETTINGS "+" writes a new settings section
///   a5  LIFECYCLE has no add — it is wiring, not a list you author here
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

/// The "+" inside the header row whose label starts with [title].
Finder _addButtonFor(String title) => find.descendant(
  of: find.ancestor(
    of: find.textContaining('$title ('),
    matching: find.byType(Row),
  ).first,
  matching: find.byIcon(Icons.add),
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late Directory tmp;
  late ChromeBridge bridge;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bundle_tools_add_');
    bridge = ChromeBridge();
    File('${tmp.path}/manifest.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 't', 'name': 'T', 'version': '1'},
        'tools': <dynamic>[],
      }),
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Map<String, dynamic> readManifest() =>
      jsonDecode(File('${tmp.path}/manifest.json').readAsStringSync())
          as Map<String, dynamic>;

  Future<void> pumpEditor(WidgetTester tester) async {
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

  testWidgets('a1 every authorable section header offers an add affordance', (
    tester,
  ) async {
    await pumpEditor(tester);
    for (final title in <String>[
      'TOOLS',
      'DOMAIN ICONS',
      '/ COMMANDS',
      'SETTINGS',
    ]) {
      expect(
        _addButtonFor(title),
        findsOneWidget,
        reason:
            '$title can be deleted from this editor, so it must be creatable '
            'here too — otherwise removing the last entry is a dead end',
      );
    }
  });

  testWidgets('a5 LIFECYCLE offers no add — it is wiring, not a list', (
    tester,
  ) async {
    await pumpEditor(tester);
    expect(_addButtonFor('LIFECYCLE'), findsNothing);
  });

  testWidgets('a2 the TOOLS "+" actually writes a tool to disk', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tester.runAsync(() async {
      await tester.tap(_addButtonFor('TOOLS'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    // `tools` is tolerated flat or nested by the editor; read either shape.
    final raw = readManifest()['tools'];
    final tools = (raw is Map ? raw['tools'] : raw) as List;
    expect(tools, hasLength(1));
    expect((tools.first as Map)['name'], 'new_tool');
  });

  testWidgets('a3 the "/ COMMANDS" "+" writes a slash command to disk', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tester.runAsync(() async {
      await tester.tap(_addButtonFor('/ COMMANDS'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    // Slash commands live under `chat`, the same place _updateSlash and
    // _deleteSlash read — not under `wiring`, which carries domain icons.
    final chat = readManifest()['chat'] as Map;
    expect(chat['slashCommands'], hasLength(1));
  });

  testWidgets('a4 the SETTINGS "+" writes a settings section to disk', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tester.runAsync(() async {
      await tester.tap(_addButtonFor('SETTINGS'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    final settings = readManifest()['settings'] as Map;
    expect(settings['sections'], hasLength(1));
  });
}
