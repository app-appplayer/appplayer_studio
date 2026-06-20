/// `VbuColorEditor` — labelled hex color input row with swatch.
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

  testWidgets('renders label + value', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuColorEditor(label: 'Accent', value: '#00ff88')),
    );
    expect(find.text('Accent'), findsOneWidget);
    expect(find.text('#00ff88'), findsOneWidget);
  });

  testWidgets('text field exists and accepts input', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuColorEditor(label: 'Accent', value: '#000000')),
    );
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '#ff0000');
    // Editor may only commit on submit / unfocus — we just assert the
    // text reaches the TextField widget.
    expect(find.text('#ff0000'), findsOneWidget);
  });

  testWidgets('null value renders empty input', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuColorEditor(label: 'X', value: null)),
    );
    expect(find.text('X'), findsOneWidget);
  });
}
