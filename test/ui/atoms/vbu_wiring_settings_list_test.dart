/// `WiringSettingsList` + `WiringSettingsRow` — tappable action rows
/// sourced from `manifest.wiring.settings[]`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders one row per entry', (tester) async {
    await tester.pumpWidget(
      _wrap(
        WiringSettingsList(
          entries: const <Map<String, dynamic>>[
            <String, dynamic>{
              'label': 'Reset DB',
              'tool': 'db.reset',
              'icon': 'reset',
            },
            <String, dynamic>{
              'label': 'Export Config',
              'tool': 'config.export',
              'icon': 'export',
            },
          ],
          onFire: (_, __) async {},
        ),
      ),
    );
    expect(find.text('Reset DB'), findsOneWidget);
    expect(find.text('Export Config'), findsOneWidget);
  });

  testWidgets('fires onFire with correct tool and args on tap', (tester) async {
    String? firedTool;
    Map<String, dynamic>? firedArgs;
    await tester.pumpWidget(
      _wrap(
        WiringSettingsList(
          entries: const <Map<String, dynamic>>[
            <String, dynamic>{
              'label': 'Clear Cache',
              'tool': 'cache.clear',
              'icon': 'clear',
              'arguments': <String, dynamic>{'scope': 'all'},
            },
          ],
          onFire: (tool, args) async {
            firedTool = tool;
            firedArgs = args;
          },
        ),
      ),
    );
    await tester.tap(find.text('Clear Cache'));
    await tester.pumpAndSettle();
    expect(firedTool, 'cache.clear');
    expect(firedArgs, <String, dynamic>{'scope': 'all'});
  });

  testWidgets('shows category badge when category is set', (tester) async {
    await tester.pumpWidget(
      _wrap(
        WiringSettingsList(
          entries: const <Map<String, dynamic>>[
            <String, dynamic>{
              'label': 'Sync',
              'tool': 'sync',
              'icon': 'sync',
              'category': 'cloud',
            },
          ],
          onFire: (_, __) async {},
        ),
      ),
    );
    expect(find.text('cloud'), findsOneWidget);
  });

  testWidgets('renders empty list without crashing', (tester) async {
    await tester.pumpWidget(
      _wrap(
        WiringSettingsList(
          entries: const <Map<String, dynamic>>[],
          onFire: (_, __) async {},
        ),
      ),
    );
    expect(find.byType(WiringSettingsList), findsOneWidget);
  });

  testWidgets('WiringSettingsRow renders label and icon', (tester) async {
    await tester.pumpWidget(
      _wrap(
        WiringSettingsRow(
          label: 'Save now',
          iconData: Icons.save_outlined,
          category: null,
          onTap: () {},
        ),
      ),
    );
    expect(find.text('Save now'), findsOneWidget);
    expect(find.byIcon(Icons.save_outlined), findsOneWidget);
  });

  testWidgets('WiringSettingsRow fires onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        WiringSettingsRow(
          label: 'Do it',
          iconData: Icons.tune,
          category: 'admin',
          onTap: () => taps++,
        ),
      ),
    );
    await tester.tap(find.text('Do it'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });
}
