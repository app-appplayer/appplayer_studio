/// `VbuRouter` — switch widget that picks one of `cases` by `value`
/// with an optional `fallback`.
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

  testWidgets('picks the case matching value', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuRouter(
          value: 'b',
          cases: <String, Widget>{
            'a': Text('case A'),
            'b': Text('case B'),
            'c': Text('case C'),
          },
        ),
      ),
    );
    expect(find.text('case B'), findsOneWidget);
    expect(find.text('case A'), findsNothing);
  });

  testWidgets('falls back when value matches no case', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuRouter(
          value: 'unknown',
          cases: <String, Widget>{'a': Text('A')},
          fallback: Text('fallback shown'),
        ),
      ),
    );
    expect(find.text('fallback shown'), findsOneWidget);
  });

  testWidgets('renders nothing visible when no match and no fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const VbuRouter(
          value: 'unknown',
          cases: <String, Widget>{'a': Text('A')},
        ),
      ),
    );
    expect(find.text('A'), findsNothing);
  });
}
