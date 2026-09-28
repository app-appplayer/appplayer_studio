/// Compose's issue call records who issued, and its status line speaks to a
/// person: the registry's ISSUED BY stayed blank for UI issues, a refusal
/// read `form_builder.approval_required: …`, and success dumped the raw
/// artifact maps.
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/form_builder/ui/compose_page.dart'
    show formFailureText;
import 'package:appplayer_studio/src/apps/form_builder/ui/form_tool_client.dart'
    show FormToolException;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final src =
      File('lib/src/apps/form_builder/ui/compose_page.dart').readAsStringSync();

  test('issue sends issuedBy', () {
    final call = src.substring(src.indexOf("'form_builder.issue'"));
    expect(call.substring(0, 400), contains("'issuedBy':"));
  });

  test('failures read as a sentence for a person', () {
    expect(src, isNot(contains("_note('\$e')")));
    expect(
      formFailureText(
        const FormToolException(
          'form_builder.approval_required',
          'This document has an approval in state "pending" — it must '
              'complete (form_builder.approve) before issuing.',
        ),
      ),
      'This document has an approval in state "pending" — it must '
      'complete before issuing.',
    );
    expect(
      formFailureText(
        const FormToolException(
          'form_builder.draft_not_found',
          'Save the draft first (form_builder.draft_save) — the issue '
              'freezes the saved content.',
        ),
      ),
      'Save the draft first — the issue freezes the saved content.',
    );
  });

  test('success lists formats, not artifact maps', () {
    expect(src, isNot(contains("\${out['artifacts']}")));
  });
}
