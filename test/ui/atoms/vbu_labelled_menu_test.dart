/// `VbuLabelledMenu<T>` — labelled dropdown picker (uses showMenu).
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

  testWidgets('renders label + current value', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuLabelledMenu<String>(
          label: 'Theme',
          value: 'dark',
          options: const <String>['light', 'dark'],
          onChanged: (_) {},
        ),
      ),
    );
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('dark'), findsOneWidget);
  });

  testWidgets('uses labels map for display when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuLabelledMenu<String>(
          label: 'Theme',
          value: 'dark',
          options: const <String>['light', 'dark'],
          labels: const <String, String>{'light': 'Light', 'dark': 'Dark mode'},
          onChanged: (_) {},
        ),
      ),
    );
    expect(find.text('Dark mode'), findsOneWidget);
  });
}
