/// `AssetGalleryView` + `AssetThumbnail` — grid view for the asset
/// registry; thumbnail resolver for material://, data:image, and fallback.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: SizedBox(width: 800, height: 600, child: child)),
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('empty assets shows no-assets placeholder text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        AssetGalleryView(
          assets: const AssetSlice(
            raw: <String, dynamic>{},
            entries: <Map<String, dynamic>>[],
          ),
          bundlePath: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No assets yet'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('shows Assets header with count', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    const entries = <Map<String, dynamic>>[
      <String, dynamic>{'id': 'logo', 'type': 'image'},
      <String, dynamic>{'id': 'icon', 'type': 'icon'},
    ];
    await tester.pumpWidget(
      _wrap(
        AssetGalleryView(
          assets: const AssetSlice(raw: <String, dynamic>{}, entries: entries),
          bundlePath: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Assets'), findsWidgets);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('renders tile id labels for entries', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    const entries = <Map<String, dynamic>>[
      <String, dynamic>{'id': 'hero_bg', 'type': 'image'},
    ];
    await tester.pumpWidget(
      _wrap(
        AssetGalleryView(
          assets: const AssetSlice(raw: <String, dynamic>{}, entries: entries),
          bundlePath: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('hero_bg'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('AssetThumbnail material: ref renders icon', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const AssetThumbnail(
          entry: <String, dynamic>{
            'type': 'icon',
            'contentRef': 'material:home',
          },
          bundlePath: null,
          size: 48,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Icon), findsOneWidget);
  });

  testWidgets('AssetThumbnail unknown type renders fallback icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const AssetThumbnail(
          entry: <String, dynamic>{'type': 'unknown'},
          bundlePath: null,
          size: 48,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Icon), findsOneWidget);
  });

  testWidgets('AssetThumbnail image type without ref shows image_outlined', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const AssetThumbnail(
          entry: <String, dynamic>{'type': 'image'},
          bundlePath: null,
          size: 48,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  });

  testWidgets('AssetThumbnail audio type shows audiotrack icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const AssetThumbnail(
          entry: <String, dynamic>{'type': 'audio'},
          bundlePath: null,
          size: 48,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.audiotrack), findsOneWidget);
  });

  testWidgets('AssetThumbnail font type shows text_fields icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const AssetThumbnail(
          entry: <String, dynamic>{'type': 'font'},
          bundlePath: null,
          size: 48,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.text_fields), findsOneWidget);
  });
}
