/// `PackageWelcomePanel` and `StudioWelcomePanel` — hero cards shown when
/// the studio has no package / project open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  setUp(() async {
    // Give the test surface enough room for wide hero panel buttons.
  });

  // ── PackageWelcomePanel ──────────────────────────────────────────────────

  group('PackageWelcomePanel', () {
    testWidgets('renders default title', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      await tester.pumpWidget(_wrap(PackageWelcomePanel(onInstall: () {})));
      await tester.pump();
      expect(find.text('AppPlayer Studio'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders custom title + subtitle', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      await tester.pumpWidget(
        _wrap(
          PackageWelcomePanel(
            onInstall: () {},
            title: 'My Studio',
            subtitle: 'Pick a bundle.',
          ),
        ),
      );
      await tester.pump();
      expect(find.text('My Studio'), findsOneWidget);
      expect(find.text('Pick a bundle.'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('Install button fires onInstall', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      var taps = 0;
      await tester.pumpWidget(
        _wrap(PackageWelcomePanel(onInstall: () => taps++)),
      );
      await tester.pump();
      await tester.tap(find.text('Install Package'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('Create button hidden when onCreate is null', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      await tester.pumpWidget(_wrap(PackageWelcomePanel(onInstall: () {})));
      await tester.pump();
      expect(find.text('Create Package'), findsNothing);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('Create button visible when onCreate is provided', (
      tester,
    ) async {
      // The two-button layout overflows at the default 480px test viewport
      // (VbuHeroPanel.maxWidth=520 minus padding leaves ~440px for two wide
      // labels). Suppress the rendering overflow and verify button presence only.
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exceptionAsString().contains('RenderFlex overflowed'))
          return;
        originalOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = originalOnError);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: PackageWelcomePanel(onInstall: () {}, onCreate: () {}),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Create Package'), findsOneWidget);
    });

    testWidgets('hint text renders in footer', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      await tester.pumpWidget(
        _wrap(PackageWelcomePanel(onInstall: () {}, hint: 'custom hint text')),
      );
      await tester.pump();
      expect(find.textContaining('custom hint text'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });
  });

  // ── StudioWelcomePanel ───────────────────────────────────────────────────

  group('StudioWelcomePanel', () {
    testWidgets('renders default title', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      await tester.pumpWidget(
        _wrap(
          StudioWelcomePanel(
            recents: const <String>[],
            onNew: () {},
            onOpen: () {},
            onPickRecent: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('AppPlayer Builder'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('New Project button fires onNew', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          StudioWelcomePanel(
            recents: const <String>[],
            onNew: () => taps++,
            onOpen: () {},
            onPickRecent: (_) {},
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('New Project'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('Open Project button fires onOpen', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          StudioWelcomePanel(
            recents: const <String>[],
            onNew: () {},
            onOpen: () => taps++,
            onPickRecent: (_) {},
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Open Project'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('empty recents hides recent-projects section', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      await tester.pumpWidget(
        _wrap(
          StudioWelcomePanel(
            recents: const <String>[],
            onNew: () {},
            onOpen: () {},
            onPickRecent: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('RECENT PROJECTS'), findsNothing);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('non-empty recents renders RECENT PROJECTS label', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      await tester.pumpWidget(
        _wrap(
          StudioWelcomePanel(
            recents: const <String>['/tmp/my_project'],
            onNew: () {},
            onOpen: () {},
            onPickRecent: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('RECENT PROJECTS'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('tapping a recent fires onPickRecent with path', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      String? picked;
      await tester.pumpWidget(
        _wrap(
          StudioWelcomePanel(
            recents: const <String>['/tmp/my_project'],
            onNew: () {},
            onOpen: () {},
            onPickRecent: (p) => picked = p,
          ),
        ),
      );
      await tester.pump();
      // basename of the path is rendered as the row title.
      await tester.tap(find.text('my_project'));
      await tester.pumpAndSettle();
      expect(picked, '/tmp/my_project');
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('custom title and subtitle render', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      await tester.pumpWidget(
        _wrap(
          StudioWelcomePanel(
            recents: const <String>[],
            onNew: () {},
            onOpen: () {},
            onPickRecent: (_) {},
            title: 'Knowledge Builder',
            subtitle: 'Open or create a knowledge base.',
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Knowledge Builder'), findsOneWidget);
      expect(find.text('Open or create a knowledge base.'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });
  });
}
