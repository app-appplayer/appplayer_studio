/// `VbuInstanceStrip` — list of selectable instance items (horizontal
/// or vertical), optional section title + add button + empty text.
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

  testWidgets('renders item labels', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        const VbuInstanceStrip(
          items: <VbuInstanceItem>[
            VbuInstanceItem(id: 'one', label: 'One'),
            VbuInstanceItem(id: 'two', label: 'Two'),
          ],
          selectedId: 'one',
        ),
      ),
    );
    expect(find.text('One'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('onSelect fires with tapped item id', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    String? picked;
    await tester.pumpWidget(
      _wrap(
        VbuInstanceStrip(
          items: const <VbuInstanceItem>[
            VbuInstanceItem(id: 'a', label: 'Alpha'),
            VbuInstanceItem(id: 'b', label: 'Beta'),
          ],
          selectedId: 'a',
          onSelect: (id) => picked = id,
        ),
      ),
    );
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(picked, 'b');
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('empty list shows emptyText', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuInstanceStrip(
          items: <VbuInstanceItem>[],
          emptyText: 'No instances yet',
        ),
      ),
    );
    expect(find.text('No instances yet'), findsOneWidget);
  });

  testWidgets('add button surfaces when addLabel + onAdd provided', (
    tester,
  ) async {
    var added = 0;
    await tester.pumpWidget(
      _wrap(
        VbuInstanceStrip(
          items: const <VbuInstanceItem>[],
          addLabel: 'New',
          onAdd: () => added++,
        ),
      ),
    );
    expect(find.text('New'), findsOneWidget);
    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();
    expect(added, 1);
  });
}
