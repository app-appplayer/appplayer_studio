/// `VbuIconEditor` — labelled icon-name input with optional resolver.
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
      _wrap(const VbuIconEditor(label: 'Icon', value: 'home')),
    );
    expect(find.text('Icon'), findsOneWidget);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('text field accepts input', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuIconEditor(label: 'Icon', value: 'home')),
    );
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'star');
    expect(find.text('star'), findsOneWidget);
  });

  testWidgets('iconResolver renders the preview icon', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuIconEditor(
          label: 'Icon',
          value: 'home',
          iconResolver: (name) => name == 'home' ? Icons.home : null,
        ),
      ),
    );
    expect(find.byIcon(Icons.home), findsOneWidget);
  });

  testWidgets('null value renders empty input', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuIconEditor(label: 'X', value: null)),
    );
    expect(find.text('X'), findsOneWidget);
  });
}
