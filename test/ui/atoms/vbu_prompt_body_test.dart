/// `VbuPromptBody` — the whole question of a prompt, scrollable, never cut at
/// the dialog's height.
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

  testWidgets('a long question scrolls to its last line inside a short box', (
    tester,
  ) async {
    final text = <String>[
      for (var i = 1; i <= 120; i++) 'line $i',
      'THE LAST LINE',
    ].join('\n');
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 400,
          height: 200,
          child: VbuDialogScaffold(
            title: 'PROMPT',
            maxHeight: 200,
            body: VbuPromptBody(text: text),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scroll.position.maxScrollExtent, greaterThan(200));
    expect(scroll.position.pixels, 0);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -20000),
    );
    await tester.pump();
    expect(scroll.position.pixels, scroll.position.maxScrollExtent);
  });

  testWidgets('a short question shows whole and can be selected', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const VbuPromptBody(text: 'Allow it?')));
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('Allow it?', findRichText: true), findsOneWidget);
  });
}
