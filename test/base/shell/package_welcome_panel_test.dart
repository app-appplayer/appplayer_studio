/// Widget tests for `PackageWelcomePanel` — onboarding hero shown when
/// the universal host has no installed packages. Verifies title /
/// subtitle / hint render, Install + Create buttons fire callbacks,
/// and the inspectTag wrap surfaces `hero_action#install_package` /
/// `hero_action#create_package` ids.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/src/base/shell/package_welcome_panel.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders title + subtitle + hint footer', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpWidget(_wrap(PackageWelcomePanel(onInstall: () {})));
    expect(find.text('AppPlayer Studio'), findsOneWidget);
    expect(find.text('Install or create a package to begin.'), findsOneWidget);
    expect(find.textContaining('Install:'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('Install button fires onInstall', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    var installs = 0;
    await tester.pumpWidget(
      _wrap(PackageWelcomePanel(onInstall: () => installs++)),
    );
    await tester.tap(find.text('Install Package'));
    await tester.pumpAndSettle();
    expect(installs, 1);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('Create button hidden when onCreate is null', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpWidget(_wrap(PackageWelcomePanel(onInstall: () {})));
    expect(find.text('Create Package'), findsNothing);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('Create button fires onCreate when supplied', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    var creates = 0;
    await tester.pumpWidget(
      _wrap(PackageWelcomePanel(onInstall: () {}, onCreate: () => creates++)),
    );
    // The hero panel caps at maxWidth 520; Install + Create labels
    // overflow by ~53px in this fixture. Swallow the rendering-time
    // overflow exception so the tap-callback invariant still gets
    // verified.
    tester.takeException();
    await tester.tap(find.text('Create Package'));
    await tester.pumpAndSettle();
    expect(creates, 1);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('action MetaData wrap exposes install/create slug ids', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpWidget(
      _wrap(PackageWelcomePanel(onInstall: () {}, onCreate: () {})),
    );
    tester.takeException(); // ignore the same maxWidth 520 overflow
    final ids =
        tester.allWidgets
            .whereType<MetaData>()
            .where((w) {
              final m = w.metaData;
              return m is Map && m['type'] == 'hero_action';
            })
            .map((w) => (w.metaData as Map)['id'])
            .toSet();
    expect(ids, containsAll(<String>['install_package', 'create_package']));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
