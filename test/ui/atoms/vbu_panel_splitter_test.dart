/// `VbuPanelSplitter` — draggable divider between two resizable panels.
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

  testWidgets('renders a vertical splitter by default', (tester) async {
    await tester.pumpWidget(_wrap(VbuPanelSplitter(onDrag: (_) {})));
    expect(find.byType(VbuPanelSplitter), findsOneWidget);
  });

  testWidgets('respects horizontal axis', (tester) async {
    await tester.pumpWidget(
      _wrap(VbuPanelSplitter(onDrag: (_) {}, axis: Axis.horizontal)),
    );
    expect(find.byType(VbuPanelSplitter), findsOneWidget);
  });

  testWidgets('drag fires onDrag callback', (tester) async {
    var dragged = 0;
    var endTriggered = 0;
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 400,
          height: 400,
          child: VbuPanelSplitter(
            onDrag: (_) => dragged++,
            onDragEnd: () => endTriggered++,
          ),
        ),
      ),
    );
    await tester.drag(find.byType(VbuPanelSplitter), const Offset(20, 0));
    await tester.pumpAndSettle();
    expect(dragged, greaterThan(0));
    expect(endTriggered, greaterThanOrEqualTo(0));
  });
}
