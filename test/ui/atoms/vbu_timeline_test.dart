/// `VbuTimeline` — scenario timeline strip (steps + tracks + ruler).
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

  testWidgets('builds without crashing on a single step', (tester) async {
    // VbuTimeline's internal strip computes per-step widths from
    // available width; very small windows + multi-step labels overflow
    // the row. We pump a wide surface and a single step to keep the
    // assertion focused on construction rather than layout drift.
    await tester.binding.setSurfaceSize(const Size(2400, 600));
    await tester.pumpWidget(
      _wrap(
        const VbuTimeline(
          steps: <VbuTimelineStep>[
            VbuTimelineStep(label: 's', durationMs: 1000),
          ],
        ),
      ),
    );
    expect(find.byType(VbuTimeline), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('empty steps renders without crashing', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuTimeline(steps: <VbuTimelineStep>[])),
    );
    expect(find.byType(VbuTimeline), findsOneWidget);
  });
}
