/// `VbuDiffHeader` + `VbuDiffSectionView` — channel diff / snapshot
/// diff atoms.
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

  testWidgets('VbuDiffHeader renders title + side labels', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuDiffHeader(
          title: 'Channel diff',
          leftLabel: 'serving',
          rightLabel: 'native',
        ),
      ),
    );
    expect(find.text('Channel diff'), findsOneWidget);
    expect(find.text('serving'), findsOneWidget);
    expect(find.text('native'), findsOneWidget);
  });

  testWidgets('VbuDiffSectionView renders rows', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        VbuDiffSectionView(
          section: const VbuDiffSection(
            title: 'pages',
            rows: <VbuDiffRow>[
              VbuDiffRow(id: 'home', status: VbuDiffStatus.leftOnly),
              VbuDiffRow(id: 'about', status: VbuDiffStatus.identical),
            ],
          ),
        ),
      ),
    );
    expect(find.text('home'), findsOneWidget);
    expect(find.text('about'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('VbuDiffSectionView renders empty fallback', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuDiffSectionView(
          section: VbuDiffSection(title: 'pages', rows: <VbuDiffRow>[]),
        ),
      ),
    );
    expect(find.text('— no entries —'), findsOneWidget);
  });
}
