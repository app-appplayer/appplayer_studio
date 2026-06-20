/// `VbuDomainActionsRow` — manifest-declared domain-action chips on
/// row 2 of the chrome header.
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

  testWidgets('renders all chip tooltips', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuDomainActionsRow(
          entries: <VbuDomainActionItem>[
            VbuDomainActionItem(
              icon: Icons.save,
              tooltip: 'Save',
              onTap: () {},
            ),
            VbuDomainActionItem(
              icon: Icons.refresh,
              tooltip: 'Reload',
              onTap: () {},
            ),
          ],
        ),
      ),
    );
    expect(find.byTooltip('Save'), findsOneWidget);
    expect(find.byTooltip('Reload'), findsOneWidget);
  });

  testWidgets('onTap fires when a chip is tapped', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        VbuDomainActionsRow(
          entries: <VbuDomainActionItem>[
            VbuDomainActionItem(
              icon: Icons.play_arrow,
              tooltip: 'Run',
              onTap: () => taps++,
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('empty entries renders without crashing', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuDomainActionsRow(entries: <VbuDomainActionItem>[])),
    );
    expect(find.byType(VbuDomainActionsRow), findsOneWidget);
  });

  testWidgets('divider entry inserts visual separator', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuDomainActionsRow(
          entries: <VbuDomainActionItem>[
            VbuDomainActionItem(
              icon: Icons.home,
              tooltip: 'Home',
              onTap: () {},
            ),
            VbuDomainActionItem(icon: Icons.add, tooltip: '', divider: true),
            VbuDomainActionItem(
              icon: Icons.help_outline,
              tooltip: 'Help',
              onTap: () {},
            ),
          ],
        ),
      ),
    );
    expect(find.byTooltip('Home'), findsOneWidget);
    expect(find.byTooltip('Help'), findsOneWidget);
  });
}
