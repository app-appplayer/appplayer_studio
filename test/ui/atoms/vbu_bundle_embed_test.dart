/// `VbuBundleEmbed` — placeholder atom that surfaces the bundle's
/// `mbdPath` + `uiPath` until a runtime factory is wired by the host.
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

  testWidgets('renders the placeholder copy with bundlePath', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(const VbuBundleEmbed(bundlePath: '/tmp/pkg.mbd')),
    );
    expect(find.textContaining('VbuBundleEmbed placeholder'), findsOneWidget);
    expect(find.textContaining('/tmp/pkg.mbd'), findsOneWidget);
    expect(find.textContaining('ui/app.json'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('respects explicit uiPath override', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        const VbuBundleEmbed(
          bundlePath: '/tmp/pkg.mbd',
          uiPath: 'ui/custom.json',
        ),
      ),
    );
    expect(find.textContaining('ui/custom.json'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
