/// `VbuStatusbar` — bottom strip with left + right slot lists. Plus
/// the two leaf atoms `VbuStatusDot` and `VbuStatusBadge`.
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

  testWidgets('renders left + right slot widgets', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuStatusbar(
          left: <Widget>[
            Text('L1', key: Key('left-1')),
            Text('L2', key: Key('left-2')),
          ],
          right: <Widget>[Text('R1', key: Key('right-1'))],
        ),
      ),
    );
    expect(find.byKey(const Key('left-1')), findsOneWidget);
    expect(find.byKey(const Key('left-2')), findsOneWidget);
    expect(find.byKey(const Key('right-1')), findsOneWidget);
  });

  testWidgets('empty slot lists render nothing crashable', (tester) async {
    await tester.pumpWidget(_wrap(const VbuStatusbar()));
    expect(find.byType(VbuStatusbar), findsOneWidget);
  });

  testWidgets('VbuStatusDot paints with a color', (tester) async {
    await tester.pumpWidget(_wrap(const VbuStatusDot(color: Colors.green)));
    expect(find.byType(VbuStatusDot), findsOneWidget);
  });

  testWidgets('VbuStatusDot respects size override', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuStatusDot(color: Colors.red, size: 16)),
    );
    final size = tester.getSize(find.byType(VbuStatusDot));
    expect(size.width, 16);
    expect(size.height, 16);
  });
}
