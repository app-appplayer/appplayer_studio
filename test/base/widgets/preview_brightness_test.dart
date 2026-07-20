import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_ui_view/appplayer_ui_view.dart' show UiTargetSnapshot;

import 'package:appplayer_studio/base.dart' show McpUiRuntimePort;

/// Preview brightness resolution matrix — the rendered runtime surface
/// must treat `theme.mode` as:
///   explicit `light` / `dark` → that brightness, regardless of host;
///   `system` / absent         → inherit the Studio chrome's effective
///                               theme (dark Studio previews dark).
void main() {
  UiTargetSnapshot snapshotWith(String? mode) => UiTargetSnapshot(
    target: 'mcp-ui:page/home',
    data: <String, dynamic>{
      'type': 'application',
      if (mode != null) 'theme': <String, dynamic>{'mode': mode},
      'routes': <String, dynamic>{'/': 'ui://pages/home'},
      'initialRoute': '/',
    },
    sourceHash: 'sha256:test',
    fetchedAt: DateTime.now(),
    source: 'test',
  );

  Future<Map<String, dynamic>> pageLoader(String uri) async =>
      <String, dynamic>{
        'type': 'page',
        'content': <String, dynamic>{'type': 'text', 'content': 'probe'},
      };

  /// Renders the port output under a host MaterialApp of [hostBrightness]
  /// and returns the platformBrightness the runtime surface sees.
  Future<Brightness> renderedBrightness(
    WidgetTester tester, {
    required Brightness hostBrightness,
    required String? bundleMode,
  }) async {
    final port = McpUiRuntimePort(pageLoader: pageLoader);
    late Widget rendered;
    await tester.runAsync(() async {
      rendered = await port.render(snapshotWith(bundleMode));
    });
    Brightness? seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: hostBrightness, useMaterial3: true),
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Column(
                children: <Widget>[
                  Expanded(child: rendered),
                  Builder(
                    builder: (context) {
                      return const SizedBox.shrink();
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    // Page resolution via pageLoader is real-async — flush event-loop
    // turns between frame pumps until the page content lands.
    for (var i = 0; i < 10 && find.text('probe').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The port wraps the runtime in MediaQuery(platformBrightness) +
    // Theme; read what the probe text's context sees.
    final probe = find.text('probe');
    if (probe.evaluate().isEmpty) {
      final texts = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .toList();
      fail('probe not rendered; visible texts: $texts');
    }
    final ctx = tester.element(probe);
    seen = MediaQuery.of(ctx).platformBrightness;
    return seen;
  }

  testWidgets('tb1: system mode inherits dark Studio host', (tester) async {
    final b = await renderedBrightness(
      tester,
      hostBrightness: Brightness.dark,
      bundleMode: 'system',
    );
    expect(b, Brightness.dark);
  });

  testWidgets('tb2: absent mode inherits light Studio host', (tester) async {
    final b = await renderedBrightness(
      tester,
      hostBrightness: Brightness.light,
      bundleMode: null,
    );
    expect(b, Brightness.light);
  });

  testWidgets('tb3: explicit light stays light under dark host', (
    tester,
  ) async {
    final b = await renderedBrightness(
      tester,
      hostBrightness: Brightness.dark,
      bundleMode: 'light',
    );
    expect(b, Brightness.light);
  });

  testWidgets('tb4: explicit dark stays dark under light host', (
    tester,
  ) async {
    final b = await renderedBrightness(
      tester,
      hostBrightness: Brightness.light,
      bundleMode: 'dark',
    );
    expect(b, Brightness.dark);
  });
}
