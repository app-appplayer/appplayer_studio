/// `VbuPathTile` — list row used by recents / file pickers (label +
/// meta + leading + trailing + selection state + tap).
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
    await tester.pumpWidget(_wrap(const VbuPathTile(label: '/tmp/foo')));
    expect(find.text('/tmp/foo'), findsOneWidget);
  });

  testWidgets('renders meta when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuPathTile(label: '/tmp/foo', meta: '2 hours ago')),
    );
    expect(find.text('2 hours ago'), findsOneWidget);
  });

  testWidgets('renders leading/trailing widgets', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuPathTile(
          label: '/x',
          leading: Icon(Icons.folder, key: Key('p-leading')),
          trailing: Icon(Icons.chevron_right, key: Key('p-trailing')),
        ),
      ),
    );
    expect(find.byKey(const Key('p-leading')), findsOneWidget);
    expect(find.byKey(const Key('p-trailing')), findsOneWidget);
  });

  testWidgets('onTap fires when callback provided', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(VbuPathTile(label: '/tap', onTap: () => taps++)),
    );
    await tester.tap(find.text('/tap'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('renders selected state without crashing', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuPathTile(label: '/sel', selected: true)),
    );
    expect(find.text('/sel'), findsOneWidget);
  });
}
