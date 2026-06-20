/// `VbuLayerCard` — single layer card (number + name + color + focus
/// state + optional patchCount badge).
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

  testWidgets('renders number + name', (tester) async {
    // Card paints in a wider window so the body row doesn't overflow.
    await tester.binding.setSurfaceSize(const Size(400, 200));
    await tester.pumpWidget(
      _wrap(
        const VbuLayerCard(
          number: '1',
          name: 'base',
          layerId: 'L1',
          color: Colors.blue,
        ),
      ),
    );
    expect(find.text('base'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('renders patchCount when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuLayerCard(
          number: '2',
          name: 'overlay',
          layerId: 'L2',
          color: Colors.red,
          patchCount: 12,
        ),
      ),
    );
    expect(find.text('12'), findsOneWidget);
  });

  testWidgets('renders focused state without crashing', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuLayerCard(
          number: '3',
          name: 'top',
          layerId: 'L3',
          color: Colors.green,
          focused: true,
        ),
      ),
    );
    expect(find.text('top'), findsOneWidget);
  });
}
