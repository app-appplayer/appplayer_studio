/// `PreviewSelfUi` — self-UI live track widget. Tests the no-spawn
/// path (spawnSimulator=false) which is safe for unit tests.
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

  testWidgets('renders without crashing when spawnSimulator=false', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const PreviewSelfUi(
          framework: SelfUiFramework.none,
          spawnSimulator: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PreviewSelfUi), findsOneWidget);
  });

  testWidgets('renders for lvgl framework without spawning', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const PreviewSelfUi(
          framework: SelfUiFramework.lvgl,
          simBuildDir: '/tmp/fake_sim',
          spawnSimulator: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PreviewSelfUi), findsOneWidget);
  });

  testWidgets('renders for qt framework without spawning', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const PreviewSelfUi(
          framework: SelfUiFramework.qt,
          simBuildDir: null,
          spawnSimulator: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PreviewSelfUi), findsOneWidget);
  });
}
