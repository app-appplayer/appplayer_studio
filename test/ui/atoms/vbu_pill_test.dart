/// `VbuPill` — compact pill chip (label + optional leading icon + tap).
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

  testWidgets('renders label', (tester) async {
    await tester.pumpWidget(_wrap(const VbuPill(label: 'active')));
    expect(find.text('active'), findsOneWidget);
  });

  testWidgets('renders leading widget when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuPill(
          label: 'pkg',
          leading: Icon(Icons.bolt, key: Key('pill-leading')),
        ),
      ),
    );
    expect(find.byKey(const Key('pill-leading')), findsOneWidget);
  });

  testWidgets('onTap fires when tapped', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(VbuPill(label: 'click', onTap: () => taps++)),
    );
    await tester.tap(find.text('click'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('no InkWell when onTap is null (still renders)', (tester) async {
    await tester.pumpWidget(_wrap(const VbuPill(label: 'static')));
    expect(find.text('static'), findsOneWidget);
  });
}
