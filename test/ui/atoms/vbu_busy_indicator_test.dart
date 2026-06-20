/// `VbuBusyIndicator` — animated thinking-dots indicator (label +
/// cycling dot animation).
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

  testWidgets('renders default label "thinking…"', (tester) async {
    await tester.pumpWidget(_wrap(const VbuBusyIndicator()));
    await tester.pump();
    expect(find.text('thinking…'), findsOneWidget);
    // Allow animation controller to settle before tear-down so the
    // ticker doesn't leak between tests.
    // Don't pumpAndSettle — the animation repeats forever, so we just
    // unmount to release the ticker.
    await tester.pumpWidget(_wrap(const SizedBox()));
  });

  testWidgets('renders custom label', (tester) async {
    await tester.pumpWidget(_wrap(const VbuBusyIndicator(label: 'loading')));
    await tester.pump();
    expect(find.text('loading'), findsOneWidget);
    // Don't pumpAndSettle — the animation repeats forever, so we just
    // unmount to release the ticker.
    await tester.pumpWidget(_wrap(const SizedBox()));
  });

  testWidgets('disposes cleanly without throwing', (tester) async {
    await tester.pumpWidget(_wrap(const VbuBusyIndicator()));
    await tester.pump();
    await tester.pumpWidget(_wrap(const SizedBox()));
    await tester.pumpAndSettle();
    // No exception expected on dispose.
  });
}
