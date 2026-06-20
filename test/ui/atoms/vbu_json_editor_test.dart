/// `VbuJsonEditor` — multi-line JSON text editor with optional parsed
/// callback (host parses the text and fires onParsed when valid).
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

  testWidgets('renders initial text', (tester) async {
    await tester.pumpWidget(_wrap(const VbuJsonEditor(initialText: '{"a":1}')));
    expect(find.text('{"a":1}'), findsOneWidget);
  });

  testWidgets('typing updates the text field', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuJsonEditor(initialText: '', placeholder: 'paste JSON')),
    );
    await tester.enterText(find.byType(TextField), '{"b":2}');
    expect(find.text('{"b":2}'), findsOneWidget);
  });

  testWidgets('readOnly disables editing', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuJsonEditor(initialText: '{"a":1}', readOnly: true)),
    );
    final TextField field = tester.widget(find.byType(TextField));
    expect(field.readOnly, isTrue);
  });
}
