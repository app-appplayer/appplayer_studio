/// `VbuPanelDialogScaffold` — panel-style dialog frame (title + body
/// + actions + optional title trailing + header extra).
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

  testWidgets('renders title', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuPanelDialogScaffold(
          title: 'Inspector',
          body: Text('body'),
          actions: <Widget>[],
        ),
      ),
    );
    expect(find.text('Inspector'), findsOneWidget);
  });

  testWidgets('renders body', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuPanelDialogScaffold(
          title: 'X',
          body: Text('body content'),
          actions: <Widget>[],
        ),
      ),
    );
    expect(find.text('body content'), findsOneWidget);
  });

  testWidgets('renders action buttons', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuPanelDialogScaffold(
          title: 'X',
          body: const Text('body'),
          actions: <Widget>[
            TextButton(
              key: const Key('act-1'),
              onPressed: () {},
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
    expect(find.byKey(const Key('act-1')), findsOneWidget);
  });

  testWidgets('renders titleTrailing when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuPanelDialogScaffold(
          title: 'X',
          body: Text('body'),
          actions: <Widget>[],
          titleTrailing: Icon(Icons.help_outline, key: Key('title-trail')),
        ),
      ),
    );
    expect(find.byKey(const Key('title-trail')), findsOneWidget);
  });

  testWidgets('renders headerExtra when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuPanelDialogScaffold(
          title: 'X',
          body: Text('body'),
          actions: <Widget>[],
          headerExtra: Text('extra header line', key: Key('hdr-extra')),
        ),
      ),
    );
    expect(find.byKey(const Key('hdr-extra')), findsOneWidget);
  });
}
