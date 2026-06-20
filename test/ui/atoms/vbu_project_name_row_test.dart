/// `VbuProjectNameRow` — project header row (name + dirty asterisk +
/// rename affordance, gated on hasProject).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/ui.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders project name when hasProject=true', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuProjectNameRow(
          projectName: 'my_pkg',
          dirty: false,
          hasProject: true,
          onRename: () {},
        ),
      ),
    );
    expect(find.text('my_pkg'), findsOneWidget);
  });

  testWidgets('dirty=true shows the unsaved tooltip', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuProjectNameRow(
          projectName: 'my_pkg',
          dirty: true,
          hasProject: true,
          onRename: () {},
        ),
      ),
    );
    expect(
      find.byTooltip('my_pkg (unsaved) — click to rename'),
      findsOneWidget,
    );
  });

  testWidgets('dirty=false tooltip lacks "(unsaved)"', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuProjectNameRow(
          projectName: 'clean',
          dirty: false,
          hasProject: true,
          onRename: () {},
        ),
      ),
    );
    expect(find.byTooltip('clean — click to rename'), findsOneWidget);
  });
}
