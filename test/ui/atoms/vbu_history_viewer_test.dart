/// `VbuHistoryViewer` — chronological list of timestamped change
/// entries (project history pane).
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

  testWidgets('renders the title', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuHistoryViewer(
          entries: <VbuHistoryEntry>[],
          title: 'Project history',
        ),
      ),
    );
    expect(find.text('Project history'), findsOneWidget);
  });

  testWidgets('empty entries shows emptyText', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuHistoryViewer(
          entries: <VbuHistoryEntry>[],
          emptyText: 'Nothing yet',
        ),
      ),
    );
    expect(find.text('Nothing yet'), findsOneWidget);
  });

  testWidgets('renders entry kindLabel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        VbuHistoryViewer(
          entries: <VbuHistoryEntry>[
            VbuHistoryEntry(
              timestamp: DateTime(2026, 5, 23, 12, 0),
              kindLabel: 'addAgent',
              changedPaths: const <String>['manifest.json'],
            ),
          ],
        ),
      ),
    );
    expect(find.text('addAgent'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
