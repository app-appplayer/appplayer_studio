/// `VbuVideoPlayer` — wraps `video_player` with optional autoplay /
/// loop / controls / aspect ratio. Heavy native dep — the constructor
/// surface is what we verify here so the widget tree at least builds.
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

  testWidgets('builds (placeholder while controller initialises)', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(640, 480));
    await tester.pumpWidget(
      _wrap(const VbuVideoPlayer(src: 'asset:placeholder.mp4')),
    );
    // No frame committed — the underlying controller is async and
    // tests don't stand up a native plugin. We only assert the widget
    // is mounted without throwing during initState.
    expect(find.byType(VbuVideoPlayer), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
    // Unmount before tear-down to release the controller cleanly.
    await tester.pumpWidget(_wrap(const SizedBox()));
  });

  testWidgets('respects explicit aspectRatio prop without throwing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(640, 480));
    await tester.pumpWidget(
      _wrap(
        const VbuVideoPlayer(src: 'asset:placeholder.mp4', aspectRatio: 16 / 9),
      ),
    );
    expect(find.byType(VbuVideoPlayer), findsOneWidget);
    await tester.pumpWidget(_wrap(const SizedBox()));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
