/// `VbuSystemNote` — system message bubble (info / error tone + delete).
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

  testWidgets('renders text', (tester) async {
    await tester.pumpWidget(_wrap(const VbuSystemNote(text: 'Saved.')));
    expect(find.text('Saved.'), findsOneWidget);
  });

  testWidgets('error=true shows error_outline icon', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuSystemNote(text: 'Boom', error: true)),
    );
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('error=false hides error_outline icon', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuSystemNote(text: 'OK', error: false)),
    );
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('text renders in both info and error tones', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuSystemNote(text: 'Boom', error: true)),
    );
    expect(find.text('Boom'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(const VbuSystemNote(text: 'OK', error: false)),
    );
    expect(find.text('OK'), findsOneWidget);
  });
}
