/// `InspectorPanel` — variant picker / session debug surface.
/// Only tests the null-project path (no filesystem needed, no timers).
/// The empty-build-dir path is skipped — the panel creates a session
/// manager whose ChangeNotifier cleanup races the test runner teardown.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: SizedBox(width: 900, height: 700, child: child)),
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('shows No project open hint when projectPath is null', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    await tester.pumpWidget(_wrap(const InspectorPanel(projectPath: null)));
    await tester.pump();
    expect(find.text('No project open'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('renders icon and body text for null project', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    await tester.pumpWidget(_wrap(const InspectorPanel(projectPath: null)));
    await tester.pump();
    expect(find.byIcon(Icons.folder_off_outlined), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
