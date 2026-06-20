/// `VbuComposer` — chat composer with multi-line input + submit button.
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

  testWidgets('renders hint text', (tester) async {
    final ctrl = TextEditingController();
    await tester.pumpWidget(
      _wrap(
        VbuComposer(
          controller: ctrl,
          onSubmit: () async {},
          hint: 'say something',
        ),
      ),
    );
    expect(find.text('say something'), findsOneWidget);
    ctrl.dispose();
  });

  testWidgets('typing updates controller', (tester) async {
    final ctrl = TextEditingController();
    await tester.pumpWidget(
      _wrap(VbuComposer(controller: ctrl, onSubmit: () async {}, hint: 'h')),
    );
    await tester.enterText(find.byType(TextField), 'hello');
    expect(ctrl.text, 'hello');
    ctrl.dispose();
  });

  testWidgets('busy=true renders without crashing', (tester) async {
    final ctrl = TextEditingController(text: 'pending');
    await tester.pumpWidget(
      _wrap(
        VbuComposer(
          controller: ctrl,
          onSubmit: () async {},
          hint: 'h',
          busy: true,
        ),
      ),
    );
    expect(find.text('pending'), findsOneWidget);
    ctrl.dispose();
  });
}
