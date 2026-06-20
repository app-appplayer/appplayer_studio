/// `VbuOverviewStrip` — horizontal strip of layer cards used in the
/// App Builder overview pane.
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

  testWidgets('renders all layer names', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        const VbuOverviewStrip(
          layers: <VbuOverviewLayer>[
            VbuOverviewLayer(
              id: 'L1',
              number: '1',
              name: 'base',
              color: Colors.blue,
            ),
            VbuOverviewLayer(
              id: 'L2',
              number: '2',
              name: 'mid',
              color: Colors.green,
            ),
          ],
          focused: 'L1',
        ),
      ),
    );
    expect(find.text('base'), findsOneWidget);
    expect(find.text('mid'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('onFocus fires when a card is tapped', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    String? focused;
    await tester.pumpWidget(
      _wrap(
        VbuOverviewStrip(
          layers: const <VbuOverviewLayer>[
            VbuOverviewLayer(
              id: 'L1',
              number: '1',
              name: 'base',
              color: Colors.blue,
            ),
            VbuOverviewLayer(
              id: 'L2',
              number: '2',
              name: 'mid',
              color: Colors.green,
            ),
          ],
          focused: 'L1',
          onFocus: (id) => focused = id,
        ),
      ),
    );
    await tester.tap(find.text('mid'));
    await tester.pumpAndSettle();
    expect(focused, 'L2');
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('empty layers renders without crashing', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuOverviewStrip(layers: <VbuOverviewLayer>[], focused: '')),
    );
    expect(find.byType(VbuOverviewStrip), findsOneWidget);
  });
}
