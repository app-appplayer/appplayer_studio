/// `VbuLabelledField` — labelled text input row used in settings forms.
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

  testWidgets('renders label', (tester) async {
    final ctrl = TextEditingController();
    await tester.pumpWidget(
      _wrap(
        VbuLabelledField(label: 'API key', controller: ctrl, hint: 'sk-...'),
      ),
    );
    expect(find.text('API key'), findsOneWidget);
    ctrl.dispose();
  });

  testWidgets('controller text appears in text field', (tester) async {
    final ctrl = TextEditingController(text: 'preset value');
    await tester.pumpWidget(
      _wrap(
        VbuLabelledField(label: 'API key', controller: ctrl, hint: 'sk-...'),
      ),
    );
    expect(find.text('preset value'), findsOneWidget);
    ctrl.dispose();
  });

  testWidgets('typing updates controller', (tester) async {
    final ctrl = TextEditingController();
    await tester.pumpWidget(
      _wrap(
        VbuLabelledField(label: 'Name', controller: ctrl, hint: 'placeholder'),
      ),
    );
    await tester.enterText(find.byType(TextField), 'hello');
    expect(ctrl.text, 'hello');
    ctrl.dispose();
  });

  testWidgets('obscure=true masks value', (tester) async {
    final ctrl = TextEditingController(text: 'secret');
    await tester.pumpWidget(
      _wrap(
        VbuLabelledField(
          label: 'Pass',
          controller: ctrl,
          hint: '••••',
          obscure: true,
        ),
      ),
    );
    final TextField field = tester.widget(find.byType(TextField));
    expect(field.obscureText, isTrue);
    ctrl.dispose();
  });

  testWidgets('trailing widget renders alongside the field', (tester) async {
    final ctrl = TextEditingController();
    await tester.pumpWidget(
      _wrap(
        VbuLabelledField(
          label: 'X',
          controller: ctrl,
          hint: 'y',
          trailing: const Icon(Icons.help_outline, key: Key('field-trailing')),
        ),
      ),
    );
    expect(find.byKey(const Key('field-trailing')), findsOneWidget);
    ctrl.dispose();
  });
}
