/// `BundleEditorPlaceholder` — generic empty-state body for per-bundle
/// editor modes. Renders a centred icon + mode label + summary + bundle path.
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

  testWidgets('renders mode label as placeholder heading', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const BundleEditorPlaceholder(
          bundlePath: '/tmp/test.mbd',
          mode: 'Manifest',
          summary: 'Edit manifest fields here.',
        ),
      ),
    );
    expect(find.textContaining('Manifest'), findsOneWidget);
  });

  testWidgets('renders summary text', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const BundleEditorPlaceholder(
          bundlePath: '/tmp/test.mbd',
          mode: 'Tools',
          summary: 'Tool definitions shown here.',
        ),
      ),
    );
    expect(find.text('Tool definitions shown here.'), findsOneWidget);
  });

  testWidgets('renders bundle path', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const BundleEditorPlaceholder(
          bundlePath: '/workspace/my.mbd',
          mode: 'Knowledge',
          summary: 'Knowledge entries.',
        ),
      ),
    );
    expect(find.text('/workspace/my.mbd'), findsOneWidget);
  });

  testWidgets('renders architecture icon', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const BundleEditorPlaceholder(
          bundlePath: '/tmp/test.mbd',
          mode: 'Agents',
          summary: 'Agents listed here.',
        ),
      ),
    );
    expect(find.byIcon(Icons.architecture_outlined), findsOneWidget);
  });
}
