/// `VbuHeroPanel` — welcome / onboarding hero card (title + subtitle +
/// action buttons + optional footer).
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
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_wrap(const VbuHeroPanel(title: 'Welcome')));
    expect(find.text('Welcome'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('renders subtitle when provided', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        const VbuHeroPanel(title: 'X', subtitle: 'pick a project to begin'),
      ),
    );
    expect(find.text('pick a project to begin'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('renders action buttons', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    var newTaps = 0;
    var openTaps = 0;
    await tester.pumpWidget(
      _wrap(
        VbuHeroPanel(
          title: 'X',
          actions: <VbuHeroAction>[
            VbuHeroAction(
              label: 'New',
              icon: Icons.add,
              onPressed: () => newTaps++,
            ),
            VbuHeroAction(
              label: 'Open',
              icon: Icons.folder_open,
              onPressed: () => openTaps++,
            ),
          ],
        ),
      ),
    );
    expect(find.text('New'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);

    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();
    expect(newTaps, 1);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('renders footer when provided', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        const VbuHeroPanel(
          title: 'X',
          footer: Text('footer line', key: Key('hero-footer')),
        ),
      ),
    );
    expect(find.byKey(const Key('hero-footer')), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('actions wrap in MetaData with hero_action type + slug id', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpWidget(
      _wrap(
        VbuHeroPanel(
          title: 'Hero',
          maxWidth: 900, // allow the two action labels to fit on one row
          actions: <VbuHeroAction>[
            VbuHeroAction(
              label: 'Install Package',
              icon: Icons.folder_open_outlined,
              onPressed: () {},
              emphasised: true,
            ),
            VbuHeroAction(
              label: 'Create Package',
              icon: Icons.add,
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    final all =
        tester.allWidgets.whereType<MetaData>().where((w) {
          final m = w.metaData;
          return m is Map && m['type'] == 'hero_action';
        }).toList();
    expect(all.length, 2);
    final ids = all.map((w) => (w.metaData as Map)['id']).toSet();
    expect(ids, containsAll(<String>['install_package', 'create_package']));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
