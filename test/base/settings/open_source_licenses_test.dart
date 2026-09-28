/// One place in the app lists every license: Settings → About → Open-source
/// licenses. It shows the Dart packages Flutter registers plus the native
/// libraries and fonts the app ships (assets/licenses/{apple,desktop}.json),
/// registered through the platform's OpenSourceLicenses.
library;

import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart' show OpenSourceLicenses;
import 'package:appplayer_studio/src/base/settings/settings_dialog.dart';
import 'package:appplayer_studio/src/base/settings/third_party_licenses.dart';
import 'package:appplayer_studio/src/base/settings/vibe_settings.dart';
import 'package:appplayer_studio/src/main/vibe_studio_host_app.dart'
    show kStudioModelCatalog;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Reads a shipped list the way the app registers it.
  Set<String> shipped(String path) => {
    for (final entry in OpenSourceLicenses.parseBundled(
      File(path).readAsStringSync(),
      from: path,
    ))
      ...entry.packages,
  };

  test('the macOS list carries the native libraries the app links', () {
    expect(
      shipped(appleLicenseList),
      containsAll(<String>[
        'FFmpeg (in ffmpeg_kit_flutter_new_full)',
        'FFmpeg: openh264 (in ffmpeg_kit_flutter_new_full)',
        'PDFium (in pdfrx)',
        'pdfium-binaries (in pdfrx)',
      ]),
    );
  });

  test('no GPL-only FFmpeg component ships (the LGPL build)', () {
    expect(
      shipped(appleLicenseList).where(
        (n) => RegExp(
          r'x264|x265|xvid|vid\.?stab',
          caseSensitive: false,
        ).hasMatch(n),
      ),
      isEmpty,
    );
  });

  test('the desktop list carries what no platform generator lists', () {
    expect(
      shipped(kDesktopLicenseList),
      containsAll(<String>[
        'QuickJS',
        'libserialport',
        'JetBrains Mono (font)',
      ]),
    );
  });

  test('registration puts both lists on the one license page', () async {
    OpenSourceLicenses.resetForTest();
    addTearDown(OpenSourceLicenses.resetForTest);
    registerThirdPartyLicenses(bundle: _FileBundle(), macOS: true);
    final packages = <String>{};
    await for (final entry in LicenseRegistry.licenses) {
      packages.addAll(entry.packages);
    }
    expect(
      packages,
      containsAll(<String>[
        'FFmpeg (in ffmpeg_kit_flutter_new_full)',
        'PDFium (in pdfrx)',
        'QuickJS',
      ]),
    );
  });

  test(
    'under the Pro tier the base lists resolve under the package prefix',
    () async {
      OpenSourceLicenses.resetForTest();
      addTearDown(OpenSourceLicenses.resetForTest);
      // Pro bundles the open studio's assets as packages/appplayer_studio/….
      registerThirdPartyLicenses(
        bundle: _FileBundle(prefix: 'packages/appplayer_studio/'),
        macOS: false,
      );
      final packages = <String>{};
      await for (final entry in LicenseRegistry.licenses) {
        packages.addAll(entry.packages);
      }
      expect(packages, containsAll(<String>['QuickJS', 'libserialport']));
    },
  );

  testWidgets('Settings → About opens the license page', (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        title: 'AppPlayer Studio',
        home: Builder(
          builder:
              (context) => Center(
                child: ElevatedButton(
                  onPressed:
                      () => showVibeSettingsDialog(
                        context,
                        VibeSettings(llmModel: kStudioModelCatalog.first.id),
                        modelOptions: kStudioModelCatalog,
                        settingsPath: '/tmp/settings.json',
                      ),
                  child: const Text('open'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('settings.openSourceLicenses'));
    await tester.scrollUntilVisible(
      button,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(button);
    // The page reads the license texts with real I/O and shows a progress
    // indicator meanwhile, so it never settles under fake time.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LicensePage), findsOneWidget);
  });
}

/// Serves asset keys from the package tree, as the app bundle would.
class _FileBundle extends CachingAssetBundle {
  _FileBundle({this.prefix = ''});

  /// Where the package tree sits inside the bundle.
  final String prefix;

  @override
  Future<ByteData> load(String key) async {
    if (!key.startsWith(prefix)) throw FlutterError('missing asset $key');
    final file = File(key.substring(prefix.length));
    if (!file.existsSync()) throw FlutterError('missing asset $key');
    return ByteData.sublistView(Uint8List.fromList(file.readAsBytesSync()));
  }
}
