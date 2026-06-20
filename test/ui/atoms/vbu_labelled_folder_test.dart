/// `VbuLabelledFolder` — labelled folder picker row (label + value +
/// hint + pick button + optional clear).
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
      _wrap(
        VbuLabelledFolder(
          label: 'Workspace',
          value: '/tmp/workspace',
          hint: 'pick a folder',
          onPick: () async {},
        ),
      ),
    );
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('/tmp/workspace'), findsOneWidget);
  });

  testWidgets('renders hint when value is empty', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuLabelledFolder(
          label: 'Workspace',
          value: '',
          hint: 'pick a folder',
          onPick: () async {},
        ),
      ),
    );
    expect(find.text('pick a folder'), findsOneWidget);
  });

  testWidgets('onClear absent when callback is null', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuLabelledFolder(
          label: 'X',
          value: '/x',
          hint: 'y',
          onPick: () async {},
        ),
      ),
    );
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('onClear shown + fires when provided', (tester) async {
    var cleared = 0;
    await tester.pumpWidget(
      _wrap(
        VbuLabelledFolder(
          label: 'X',
          value: '/x',
          hint: 'y',
          onPick: () async {},
          onClear: () => cleared++,
        ),
      ),
    );
    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(cleared, 1);
  });
}
