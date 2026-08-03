// `studio.ui.type` has to edit the way a person edits.
//
// It used to write `controller.value` directly, with a comment claiming that
// was "the same path a real keystroke takes". It is not: Flutter calls
// `TextField.onChanged` from `EditableTextState._formatAndSetValue`, which runs
// only on a *user* edit. A controller write repaints the field and notifies
// controller listeners — nothing more. Every page that recorded "the user
// touched this" from `onChanged` was therefore invisible to a driver, and two
// pages had already written workarounds saying `studio.ui.type` "bypasses
// onChanged" — a contradiction sitting in the tree, with the driver's own
// comment on the wrong side of it.
//
// The cost was not a broken product: humans typed fine. The cost was that QA
// could not tell a working guard from a missing one, and read its own blind
// spot as a product defect (QA-form_builder TC-FB-023).
//
// These lock both directions — that the real path fires `onChanged`, and that
// the old path does not — so a revert cannot pass quietly.

import 'package:appplayer_studio/src/base/install/ui_control_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<(TextEditingController, List<String>)> pumpField(
    WidgetTester tester, {
    String initial = '',
  }) async {
    final controller = TextEditingController(text: initial);
    final seen = <String>[];
    final focus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            controller: controller,
            focusNode: focus,
            onChanged: seen.add,
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    return (controller, seen);
  }

  testWidgets('typing into the focused field fires onChanged', (tester) async {
    final (controller, seen) = await pumpField(tester);

    final field = findFocusedEditableText();
    expect(field, isNotNull, reason: 'the field was focused');

    final written = typeIntoField(field!, 'hello');
    await tester.pump();

    expect(written.asKeystroke, isTrue);
    expect(controller.text, 'hello');
    expect(seen, ['hello'],
        reason: 'onChanged must fire — a guard that reads it is the point');
  });

  testWidgets('a bare controller write does not — this is why the tool '
      'does not do that', (tester) async {
    final (controller, seen) = await pumpField(tester);
    await tester.pump();

    controller.value = const TextEditingValue(
      text: 'hello',
      selection: TextSelection.collapsed(offset: 5),
    );
    await tester.pump();

    expect(controller.text, 'hello', reason: 'the text does land…');
    expect(seen, isEmpty, reason: '…but nothing that watches onChanged sees it');
  });

  testWidgets('clear:false appends and still fires onChanged', (tester) async {
    final (controller, seen) = await pumpField(tester, initial: 'ab');
    final field = findFocusedEditableText()!;

    final written = typeIntoField(field, 'cd', clear: false);
    await tester.pump();

    expect(written.text, 'abcd');
    expect(controller.text, 'abcd');
    expect(seen, ['abcd']);
  });

  testWidgets('no focused field is reported as such, not guessed at',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('nothing focusable'))),
    );
    expect(findFocusedEditableText(), isNull);
  });
}
