import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_ui_view/appplayer_ui_view.dart' show UiTargetSnapshot;
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    show ThemeManager;

import 'package:appplayer_studio/base.dart' show McpUiRuntimePort;

/// Theme rebaseline discipline (sequential-transition contamination):
/// a definition that declares no palette must NOT inherit the previous
/// definition's palette from the singleton ThemeManager, and must land on
/// a content-ful baseline that carries a REAL dark token set.
void main() {
  UiTargetSnapshot snap(Map<String, dynamic>? theme) => UiTargetSnapshot(
    target: 'mcp-ui:page/home',
    data: <String, dynamic>{
      'type': 'application',
      if (theme != null) 'theme': theme,
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

  Future<void> render(
    WidgetTester tester,
    Map<String, dynamic>? theme, {
    Brightness host = Brightness.dark,
  }) async {
    // Sequential transition, matching real surface usage (exclusive
    // mounting): unmount the previous runtime BEFORE creating the next
    // one, or the two MaterialApps collide on the singleton navigatorKey.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final port = McpUiRuntimePort(
      pageLoader: pageLoader,
      hostBrightnessOf: () => host,
    );
    late Widget w;
    await tester.runAsync(() async => w = await port.render(snap(theme)));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: host, useMaterial3: true),
        home: Scaffold(body: w),
      ),
    );
    for (var i = 0; i < 10 && find.text('probe').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (find.text('probe').evaluate().isEmpty) {
      final texts = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .toList();
      fail('probe not rendered; visible texts: $texts');
    }
  }

  testWidgets('rb1: themeless def does not inherit prior palette', (
    tester,
  ) async {
    // A: definition with a loud custom palette.
    await render(tester, <String, dynamic>{
      'mode': 'dark',
      'color': <String, dynamic>{'primary': '#FF0000'},
    });
    final contaminated = ThemeManager.instance.theme;
    expect((contaminated['color'] as Map?)?['primary'], '#FF0000');

    // B: themeless definition — must rebaseline, not inherit A's red.
    await render(tester, null);
    final rebased = ThemeManager.instance.theme;
    expect((rebased['color'] as Map?)?['primary'], isNot('#FF0000'));
    // Content-ful baseline: a real dark variant token set exists.
    expect(rebased['dark'], isA<Map<dynamic, dynamic>>());
    expect((rebased['dark'] as Map).isNotEmpty, isTrue);
  });

  testWidgets('rb2: mode-only override keeps mode on the baseline', (
    tester,
  ) async {
    await render(tester, <String, dynamic>{'mode': 'light'});
    expect(ThemeManager.instance.themeMode, 'light');
    expect(ThemeManager.instance.theme['dark'], isA<Map<dynamic, dynamic>>());
  });

  testWidgets('rb3: def with own palette is untouched by rebaseline', (
    tester,
  ) async {
    await render(tester, <String, dynamic>{
      'mode': 'dark',
      'color': <String, dynamic>{'primary': '#00FF00'},
    });
    expect(
      (ThemeManager.instance.theme['color'] as Map?)?['primary'],
      '#00FF00',
    );
  });

  testWidgets('rb4: foreign singleton reset is healed by the liveness guard', (
    tester,
  ) async {
    await render(tester, null);
    expect(ThemeManager.instance.theme['dark'], isA<Map<dynamic, dynamic>>());

    // Simulate another runtime's destroy() resetting the singleton behind
    // the host's back (mcp_ui_runtime.dart calls ThemeManager.instance
    // .reset() on dispose — no host hook).
    ThemeManager.instance.reset();

    // reset() wipes WITHOUT notifying — the guard's periodic liveness
    // check (500ms) catches it even with no rebuild in between.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(
      ThemeManager.instance.theme['dark'],
      isA<Map<dynamic, dynamic>>(),
      reason: 'guard must restore the baseline after a foreign reset',
    );
    expect((ThemeManager.instance.theme['dark'] as Map).isNotEmpty, isTrue);
    expect(ThemeManager.instance.flutterThemeMode, ThemeMode.dark);
  });
}
