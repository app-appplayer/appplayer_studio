import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' show CanonicalChange;
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    show ThemeManager;

import 'package:appplayer_studio/base.dart'
    show PreviewMcpUi, WorkspaceCanonical;

/// Reproduces the live toggle sequence: System → Light → System. The
/// return leg must re-render with the inherited (host) brightness, not
/// keep the last explicit override.
class _FakeCanonical implements WorkspaceCanonical {
  final StreamController<CanonicalChange> _changes =
      StreamController<CanonicalChange>.broadcast(sync: true);

  @override
  Stream<CanonicalChange> get changes => _changes.stream;

  @override
  Map<String, dynamic> get currentJson => <String, dynamic>{
    'ui': <String, dynamic>{
      'type': 'application',
      'initialRoute': '/home',
      'routes': <String, dynamic>{'/home': 'ui://pages/home'},
      'pages': <String, dynamic>{
        'home': <String, dynamic>{
          'type': 'page',
          'content': <String, dynamic>{'type': 'text', 'content': 'probe'},
        },
      },
    },
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  Widget host(Widget child) => MaterialApp(
    theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
    home: Scaffold(body: child),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10 && find.text('probe').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('probe'), findsOneWidget);
  }

  Brightness seen(WidgetTester tester) =>
      MediaQuery.of(tester.element(find.text('probe'))).platformBrightness;

  testWidgets('mf1: previewMode light→null returns to inherited dark', (
    tester,
  ) async {
    final canonical = _FakeCanonical();
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      host(
        PreviewMcpUi(canonical: canonical, focusPageId: 'home'),
      ),
    );
    await settle(tester);
    expect(seen(tester), Brightness.dark, reason: 'system inherits dark host');
    expect(
      ThemeManager.instance.flutterThemeMode,
      ThemeMode.dark,
      reason: 'singleton pinned to host brightness on system render',
    );

    await tester.pumpWidget(
      host(
        PreviewMcpUi(
          canonical: canonical,
          focusPageId: 'home',
          previewMode: 'light',
        ),
      ),
    );
    await settle(tester);
    expect(seen(tester), Brightness.light, reason: 'explicit light override');
    expect(ThemeManager.instance.flutterThemeMode, ThemeMode.light);

    await tester.pumpWidget(
      host(
        PreviewMcpUi(canonical: canonical, focusPageId: 'home'),
      ),
    );
    await settle(tester);
    expect(
      seen(tester),
      Brightness.dark,
      reason: 'back to System must re-inherit the dark host, not stay light',
    );
    // The singleton ThemeManager keeps the previous surface's explicit
    // mode ('light') in `_themeMode`; without the per-render re-pin the
    // live canvas showed the stale light scheme. The pin must win.
    expect(
      ThemeManager.instance.flutterThemeMode,
      ThemeMode.dark,
      reason: 'per-render host pin overrides the stale singleton mode',
    );
  });
}
