/// `VbuActivityBar` — left-rail icon bar (groups of activity items
/// with tooltips + tap handlers).
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

  testWidgets('renders all item tooltips', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuActivityBar(
          groups: <List<VbuActivityBarItem>>[
            <VbuActivityBarItem>[
              VbuActivityBarItem(
                tooltip: 'Home',
                icon: Icons.home,
                onTap: () {},
              ),
              VbuActivityBarItem(
                tooltip: 'Builder',
                icon: Icons.build,
                onTap: () {},
              ),
            ],
          ],
        ),
      ),
    );
    expect(find.byTooltip('Home'), findsOneWidget);
    expect(find.byTooltip('Builder'), findsOneWidget);
  });

  testWidgets('onTap fires when an item is tapped', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        VbuActivityBar(
          groups: <List<VbuActivityBarItem>>[
            <VbuActivityBarItem>[
              VbuActivityBarItem(
                tooltip: 'Run',
                icon: Icons.play_arrow,
                onTap: () => taps++,
              ),
            ],
          ],
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('empty groups render nothing crashable', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuActivityBar(groups: <List<VbuActivityBarItem>>[])),
    );
    expect(find.byType(VbuActivityBar), findsOneWidget);
  });

  testWidgets('multiple groups separated', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuActivityBar(
          groups: <List<VbuActivityBarItem>>[
            <VbuActivityBarItem>[
              VbuActivityBarItem(tooltip: 'A', icon: Icons.star, onTap: () {}),
            ],
            <VbuActivityBarItem>[
              VbuActivityBarItem(tooltip: 'B', icon: Icons.bolt, onTap: () {}),
            ],
          ],
        ),
      ),
    );
    expect(find.byTooltip('A'), findsOneWidget);
    expect(find.byTooltip('B'), findsOneWidget);
  });
}
