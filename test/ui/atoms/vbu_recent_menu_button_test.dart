/// `VbuRecentMenuButton` — IconButton that opens a recents dropdown
/// (header label + tap-to-pick rows).
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

  testWidgets('renders tooltip from default value', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuRecentMenuButton(
          recents: const <String>['/a', '/b'],
          onPick: (_) {},
        ),
      ),
    );
    expect(find.byTooltip('Recent'), findsOneWidget);
  });

  testWidgets('renders empty list without crashing', (tester) async {
    await tester.pumpWidget(
      _wrap(VbuRecentMenuButton(recents: const <String>[], onPick: (_) {})),
    );
    expect(find.byType(VbuRecentMenuButton), findsOneWidget);
  });

  testWidgets('uses custom tooltip when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuRecentMenuButton(
          recents: const <String>[],
          onPick: (_) {},
          tooltip: 'Open recent',
        ),
      ),
    );
    expect(find.byTooltip('Open recent'), findsOneWidget);
  });
}
