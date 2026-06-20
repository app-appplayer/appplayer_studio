/// `VbuPaneHeader` — uppercase section label + actions row inside a panel.
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
    await tester.pumpWidget(_wrap(const VbuPaneHeader(label: 'TOOLS')));
    expect(find.text('TOOLS'), findsOneWidget);
  });

  testWidgets('renders action widgets', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuPaneHeader(
          label: 'TOOLS',
          actions: <Widget>[
            Icon(Icons.add, key: Key('act-add')),
            Icon(Icons.refresh, key: Key('act-refresh')),
          ],
        ),
      ),
    );
    expect(find.byKey(const Key('act-add')), findsOneWidget);
    expect(find.byKey(const Key('act-refresh')), findsOneWidget);
  });

  testWidgets('onClear button hidden when callback is null', (tester) async {
    await tester.pumpWidget(_wrap(const VbuPaneHeader(label: 'TOOLS')));
    expect(find.byTooltip('Clear'), findsNothing);
  });

  testWidgets('onClear button shown when callback provided', (tester) async {
    await tester.pumpWidget(
      _wrap(VbuPaneHeader(label: 'TOOLS', onClear: () async {})),
    );
    expect(find.byTooltip('Clear'), findsOneWidget);
  });

  testWidgets('onClear fires on button tap', (tester) async {
    var fired = 0;
    await tester.pumpWidget(
      _wrap(
        VbuPaneHeader(
          label: 'TOOLS',
          onClear: () async {
            fired++;
          },
        ),
      ),
    );
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(fired, 1);
  });

  testWidgets('custom clearTooltip is applied', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuPaneHeader(
          label: 'TOOLS',
          onClear: () async {},
          clearTooltip: 'Reset all',
        ),
      ),
    );
    expect(find.byTooltip('Reset all'), findsOneWidget);
  });
}
