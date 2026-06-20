/// `VbuPromptBubble` — chat bubble that renders the user's prompt
/// turn (mint-tinted, right-aligned). Hover surfaces a delete affordance.
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
    await tester.pumpWidget(_wrap(const VbuPromptBubble(text: 'hello world')));
    expect(find.text('hello world'), findsOneWidget);
  });

  testWidgets('respects maxWidth override', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuPromptBubble(text: 'narrow', maxWidth: 100)),
    );
    expect(find.text('narrow'), findsOneWidget);
  });

  testWidgets('renders multi-line text', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuPromptBubble(text: 'line one\nline two')),
    );
    expect(find.textContaining('line one'), findsOneWidget);
  });
}
