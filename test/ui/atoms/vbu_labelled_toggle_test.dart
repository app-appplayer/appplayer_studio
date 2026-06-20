/// `VbuLabelledToggle` widget — boolean settings row (checkbox + label
/// + optional hint). Verifies render, tap toggles, hint visibility.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/ui.dart';

Widget _wrap(Widget child) {
  return MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));
}

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders label', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuLabelledToggle(label: 'Debug mode', value: false, onChanged: (_) {}),
      ),
    );
    expect(find.text('Debug mode'), findsOneWidget);
  });

  testWidgets('renders hint when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuLabelledToggle(
          label: 'Debug mode',
          hint: 'Enables verbose logging',
          value: false,
          onChanged: (_) {},
        ),
      ),
    );
    expect(find.text('Enables verbose logging'), findsOneWidget);
  });

  testWidgets('hint is absent when not provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuLabelledToggle(label: 'Debug mode', value: false, onChanged: (_) {}),
      ),
    );
    expect(find.text('Enables verbose logging'), findsNothing);
  });

  testWidgets('checked icon = check_box, unchecked = check_box_outline_blank', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(VbuLabelledToggle(label: 'On', value: true, onChanged: (_) {})),
    );
    expect(find.byIcon(Icons.check_box), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsNothing);

    await tester.pumpWidget(
      _wrap(VbuLabelledToggle(label: 'Off', value: false, onChanged: (_) {})),
    );
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
  });

  testWidgets('tap toggles value', (tester) async {
    final received = <bool>[];
    await tester.pumpWidget(
      _wrap(
        VbuLabelledToggle(label: 'Flip', value: false, onChanged: received.add),
      ),
    );
    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();
    expect(received, <bool>[true]);
  });

  testWidgets('tap inverts current value (true → false)', (tester) async {
    final received = <bool>[];
    await tester.pumpWidget(
      _wrap(
        VbuLabelledToggle(label: 'Flip', value: true, onChanged: received.add),
      ),
    );
    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();
    expect(received, <bool>[false]);
  });
}
