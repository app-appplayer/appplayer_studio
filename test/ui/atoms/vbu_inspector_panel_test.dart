/// `VbuInspectorPanel` — variant picker + device frame placeholder
/// used by the App Builder preview / inspector zone.
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

  testWidgets('renders variant labels', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        const VbuInspectorPanel(
          variants: <VbuInspectorVariant>[
            VbuInspectorVariant(id: 'a', label: 'Alpha'),
            VbuInspectorVariant(id: 'b', label: 'Beta'),
          ],
          activeVariantId: 'a',
        ),
      ),
    );
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('onVariantChange fires when a non-active variant is tapped', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    String? selected;
    await tester.pumpWidget(
      _wrap(
        VbuInspectorPanel(
          variants: const <VbuInspectorVariant>[
            VbuInspectorVariant(id: 'a', label: 'Alpha'),
            VbuInspectorVariant(id: 'b', label: 'Beta'),
          ],
          activeVariantId: 'a',
          onVariantChange: (id) => selected = id,
        ),
      ),
    );
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(selected, 'b');
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('empty variant list renders without crashing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(const VbuInspectorPanel(variants: <VbuInspectorVariant>[])),
    );
    expect(find.byType(VbuInspectorPanel), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
