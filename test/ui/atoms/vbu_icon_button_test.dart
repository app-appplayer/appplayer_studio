/// `VbuIconButton` — small tooltipped icon button with hover emphasis.
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

  testWidgets('renders tooltip + icon', (tester) async {
    await tester.pumpWidget(
      _wrap(VbuIconButton(tooltip: 'Save', icon: Icons.save, onTap: () {})),
    );
    expect(find.byTooltip('Save'), findsOneWidget);
    expect(find.byIcon(Icons.save), findsOneWidget);
  });

  testWidgets('onTap fires when tapped', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        VbuIconButton(tooltip: 'Click', icon: Icons.add, onTap: () => taps++),
      ),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('renders in emphasised mode', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuIconButton(
          tooltip: 'Emphasised',
          icon: Icons.star,
          onTap: () {},
          emphasised: true,
        ),
      ),
    );
    expect(find.byIcon(Icons.star), findsOneWidget);
  });
}
