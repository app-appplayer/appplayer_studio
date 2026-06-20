/// `VbuSlashChips` — horizontal row of `/command` chips used in the
/// composer to surface bundle-declared slash commands.
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

  testWidgets('renders all command labels', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuSlashChips(
          chips: <VbuSlashChipItem>[
            VbuSlashChipItem(command: '/agents'),
            VbuSlashChipItem(command: '/wire'),
            VbuSlashChipItem(command: '/help'),
          ],
        ),
      ),
    );
    expect(find.text('/agents'), findsOneWidget);
    expect(find.text('/wire'), findsOneWidget);
    expect(find.text('/help'), findsOneWidget);
  });

  testWidgets('empty chips list renders nothing crashable', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuSlashChips(chips: <VbuSlashChipItem>[])),
    );
    expect(find.text('/'), findsNothing);
  });

  testWidgets('onTap fires when chip is tapped', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        VbuSlashChips(
          chips: <VbuSlashChipItem>[
            VbuSlashChipItem(command: '/run', onTap: () => taps++),
          ],
        ),
      ),
    );
    await tester.tap(find.text('/run'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });
}
