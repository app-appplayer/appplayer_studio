/// `VbuMiniPreview` — tiny visual placeholder rendering a layer
/// indicator (e.g. used in the channel strip).
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

  testWidgets('renders with default size', (tester) async {
    await tester.pumpWidget(_wrap(const VbuMiniPreview(layer: 'serving')));
    // Should at least build a Container of the default 140×48 — verify
    // SizedBox dimensions if present.
    final size = tester.getSize(find.byType(VbuMiniPreview));
    expect(size.width, greaterThan(0));
    expect(size.height, greaterThan(0));
  });

  testWidgets('respects explicit size override', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuMiniPreview(layer: 'serving', size: Size(200, 80))),
    );
    final size = tester.getSize(find.byType(VbuMiniPreview));
    expect(size.width, 200);
    expect(size.height, 80);
  });

  testWidgets('renders distinct layers without crashing', (tester) async {
    for (final layer in <String>['serving', 'native', 'preview']) {
      await tester.pumpWidget(_wrap(VbuMiniPreview(layer: layer)));
      await tester.pump();
    }
  });
}
