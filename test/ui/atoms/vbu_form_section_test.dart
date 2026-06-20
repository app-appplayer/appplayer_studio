/// `VbuFormSection` — settings form section (label header + child rows).
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

  testWidgets('renders label uppercased', (tester) async {
    // VbuFormSection forces the section header to uppercase so authors
    // don't have to remember the convention.
    await tester.pumpWidget(
      _wrap(
        const VbuFormSection(
          label: 'General',
          children: <Widget>[Text('row 1')],
        ),
      ),
    );
    expect(find.text('GENERAL'), findsOneWidget);
  });

  testWidgets('renders all children', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuFormSection(
          label: 'Adv',
          children: <Widget>[Text('row 1'), Text('row 2'), Text('row 3')],
        ),
      ),
    );
    expect(find.text('row 1'), findsOneWidget);
    expect(find.text('row 2'), findsOneWidget);
    expect(find.text('row 3'), findsOneWidget);
  });

  testWidgets('renders zero-child section without throwing', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuFormSection(label: 'Empty', children: <Widget>[])),
    );
    expect(find.text('EMPTY'), findsOneWidget);
  });
}
