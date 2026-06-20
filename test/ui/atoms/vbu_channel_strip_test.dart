/// `VbuChannelStrip` — channel selector (serving / native / …) with
/// optional context menu.
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

  testWidgets('renders all channel labels', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuChannelStrip(
          channels: <String>['serving', 'native'],
          activeChannel: 'serving',
        ),
      ),
    );
    expect(find.text('serving'), findsOneWidget);
    expect(find.text('native'), findsOneWidget);
  });

  testWidgets('onSelect fires with tapped channel id', (tester) async {
    String? picked;
    await tester.pumpWidget(
      _wrap(
        VbuChannelStrip(
          channels: const <String>['serving', 'native'],
          activeChannel: 'serving',
          onSelect: (id) => picked = id,
        ),
      ),
    );
    await tester.tap(find.text('native'));
    await tester.pumpAndSettle();
    expect(picked, 'native');
  });

  testWidgets('empty channels renders without crashing', (tester) async {
    await tester.pumpWidget(_wrap(const VbuChannelStrip(channels: <String>[])));
    expect(find.byType(VbuChannelStrip), findsOneWidget);
  });
}
