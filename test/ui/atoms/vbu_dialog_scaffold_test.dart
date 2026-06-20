/// `VbuDialogScaffold` — modal-dialog frame (title + subtitle + body
/// + actions row).
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
      _wrap(const VbuDialogScaffold(title: 'Settings', body: Text('body'))),
    );
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('renders subtitle when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuDialogScaffold(
          title: 'Settings',
          subtitle: 'Configure the studio',
          body: Text('body'),
        ),
      ),
    );
    expect(find.text('Configure the studio'), findsOneWidget);
  });

  testWidgets('renders body content', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuDialogScaffold(title: 'X', body: Text('body content here')),
      ),
    );
    expect(find.text('body content here'), findsOneWidget);
  });

  testWidgets('renders action buttons', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuDialogScaffold(
          title: 'X',
          body: const Text('body'),
          actions: <Widget>[
            TextButton(
              key: const Key('act-cancel'),
              onPressed: () {},
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('act-save'),
              onPressed: () {},
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    expect(find.byKey(const Key('act-cancel')), findsOneWidget);
    expect(find.byKey(const Key('act-save')), findsOneWidget);
  });

  testWidgets('renders titleIcon when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuDialogScaffold(
          title: 'X',
          titleIcon: Icons.settings,
          body: Text('body'),
        ),
      ),
    );
    expect(find.byIcon(Icons.settings), findsOneWidget);
  });

  testWidgets('renders leadingAction when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuDialogScaffold(
          title: 'X',
          body: const Text('body'),
          leadingAction: IconButton(
            key: const Key('back-btn'),
            icon: const Icon(Icons.arrow_back),
            onPressed: () {},
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('back-btn')), findsOneWidget);
  });
}
