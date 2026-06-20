/// `VbuTitleBar` — thin (28px) page-chrome strip for a bundle's UI
/// title. Verifies title / subtitle / leading / trailing render.
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

  testWidgets('renders title', (tester) async {
    await tester.pumpWidget(_wrap(const VbuTitleBar(title: 'my_package')));
    expect(find.text('my_package'), findsOneWidget);
  });

  testWidgets('renders subtitle when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuTitleBar(title: 'pkg', subtitle: 'v0.1.0')),
    );
    expect(find.text('pkg'), findsOneWidget);
    expect(find.text('v0.1.0'), findsOneWidget);
  });

  testWidgets('no subtitle when not provided', (tester) async {
    await tester.pumpWidget(_wrap(const VbuTitleBar(title: 'pkg')));
    expect(find.text('v0.1.0'), findsNothing);
  });

  testWidgets('renders leading widget', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuTitleBar(
          title: 'pkg',
          leading: Icon(Icons.folder, key: Key('leading-icon')),
        ),
      ),
    );
    expect(find.byKey(const Key('leading-icon')), findsOneWidget);
  });

  testWidgets('renders all trailing widgets', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuTitleBar(
          title: 'pkg',
          trailing: <Widget>[
            Icon(Icons.save, key: Key('t-save')),
            Icon(Icons.close, key: Key('t-close')),
          ],
        ),
      ),
    );
    expect(find.byKey(const Key('t-save')), findsOneWidget);
    expect(find.byKey(const Key('t-close')), findsOneWidget);
  });

  testWidgets('default height matches token (titlebarHeight)', (tester) async {
    await tester.pumpWidget(_wrap(const VbuTitleBar(title: 'pkg')));
    final container =
        tester.firstWidget(find.byType(Container).first) as Container;
    expect(
      container.constraints?.maxHeight ?? container.constraints?.minHeight,
      VbuTokens.titlebarHeight,
    );
  });

  testWidgets('respects explicit height override', (tester) async {
    await tester.pumpWidget(_wrap(const VbuTitleBar(title: 'pkg', height: 40)));
    final container =
        tester.firstWidget(find.byType(Container).first) as Container;
    expect(
      container.constraints?.maxHeight ?? container.constraints?.minHeight,
      40,
    );
  });
}
