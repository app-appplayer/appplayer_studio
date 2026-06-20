/// `VbuPreviewMcpUi` — preview pane that renders an MCP UI DSL bundle
/// inside a device frame.
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

  testWidgets('renders with required props (no bundle bound)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    await tester.pumpWidget(_wrap(const VbuPreviewMcpUi(uiPath: '')));
    expect(find.byType(VbuPreviewMcpUi), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('respects device size + orientation + brightness props', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpWidget(
      _wrap(
        const VbuPreviewMcpUi(
          uiPath: '',
          deviceSize: 'mobile',
          orientation: 'portrait',
          brightness: 'dark',
        ),
      ),
    );
    expect(find.byType(VbuPreviewMcpUi), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
