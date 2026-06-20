/// `ProjectHeader` — three-row chrome header (project name + lifecycle
/// actions + undo/redo/domain verbs). Also covers `HeaderAction`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

// Provides a generous surface so every row of the header fits.
Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: SizedBox(width: 400, height: 200, child: child)),
);

ProjectHeader _minimal({
  String projectName = 'MyProject',
  bool dirty = false,
  bool canUndo = false,
  bool canRedo = false,
  bool hasProject = true,
  VoidCallback? onNew,
  VoidCallback? onSave,
  VoidCallback? onUndo,
  VoidCallback? onRedo,
  VoidCallback? onSettings,
  VoidCallback? onHistory,
  List<HeaderAction> trailing = const <HeaderAction>[],
  List<String> recentProjects = const <String>[],
}) {
  return ProjectHeader(
    projectName: projectName,
    dirty: dirty,
    canUndo: canUndo,
    canRedo: canRedo,
    hasProject: hasProject,
    onNew: onNew,
    onOpen: () {},
    onOpenRecent: (_) {},
    onSave: onSave ?? () {},
    onSaveAs: () {},
    onRevert: () {},
    onUndo: onUndo ?? () {},
    onRedo: onRedo ?? () {},
    onRename: () {},
    onCloseProject: () {},
    onHistory: onHistory ?? () {},
    onSettings: onSettings ?? () {},
    trailing: trailing,
    recentProjects: recentProjects,
  );
}

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders project name', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 200));
    await tester.pumpWidget(_wrap(_minimal(projectName: 'MyBundle')));
    await tester.pump();
    expect(find.text('MyBundle'), findsOneWidget);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('settings icon tappable and fires onSettings', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 200));
    var taps = 0;
    await tester.pumpWidget(_wrap(_minimal(onSettings: () => taps++)));
    await tester.pump();
    // Settings icon is present (tooltip "Settings").
    final settingsTooltip = find.byWidgetPredicate(
      (w) => w is Tooltip && w.message == 'Settings',
    );
    expect(settingsTooltip, findsOneWidget);
    await tester.tap(settingsTooltip);
    await tester.pumpAndSettle();
    expect(taps, 1);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('history icon fires onHistory', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 200));
    var taps = 0;
    await tester.pumpWidget(_wrap(_minimal(onHistory: () => taps++)));
    await tester.pump();
    final historyTooltip = find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message as String).contains('Change history'),
    );
    expect(historyTooltip, findsOneWidget);
    await tester.tap(historyTooltip);
    await tester.pumpAndSettle();
    expect(taps, 1);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('undo fires when canUndo is true and hasProject', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 200));
    var undoTaps = 0;
    await tester.pumpWidget(
      _wrap(_minimal(canUndo: true, onUndo: () => undoTaps++)),
    );
    await tester.pump();
    final undoTooltip = find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message as String).contains('Undo last change'),
    );
    expect(undoTooltip, findsOneWidget);
    await tester.tap(undoTooltip);
    await tester.pumpAndSettle();
    expect(undoTaps, 1);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('save tooltip shows "Save" text when dirty', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 200));
    await tester.pumpWidget(_wrap(_minimal(dirty: true)));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message as String) == 'Save',
      ),
      findsOneWidget,
    );
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('trailing HeaderAction is rendered', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 200));
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        _minimal(
          trailing: <HeaderAction>[
            HeaderAction(
              tooltip: 'Build now',
              icon: Icons.build_outlined,
              onTap: () => taps++,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    // The "Build now" tooltip should exist.
    final buildTooltip = find.byWidgetPredicate(
      (w) => w is Tooltip && w.message == 'Build now',
    );
    expect(buildTooltip, findsOneWidget);
    await tester.tap(buildTooltip);
    await tester.pumpAndSettle();
    expect(taps, 1);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('panel toggle button shown when leftPanelVisible is set', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 200));
    var toggleTaps = 0;
    final w = ProjectHeader(
      projectName: 'Proj',
      dirty: false,
      canUndo: false,
      canRedo: false,
      hasProject: true,
      onOpen: () {},
      onOpenRecent: (_) {},
      onSave: () {},
      onSaveAs: () {},
      onRevert: () {},
      onUndo: () {},
      onRedo: () {},
      onRename: () {},
      onCloseProject: () {},
      onHistory: () {},
      onSettings: () {},
      leftPanelVisible: true,
      onToggleLeftPanel: () => toggleTaps++,
    );
    await tester.pumpWidget(_wrap(w));
    await tester.pump();
    expect(find.byIcon(Icons.menu_open), findsOneWidget);
    await tester.tap(find.byIcon(Icons.menu_open));
    await tester.pumpAndSettle();
    expect(toggleTaps, 1);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('renders without crashing when hasProject is false', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 200));
    await tester.pumpWidget(
      _wrap(_minimal(hasProject: false, projectName: 'No project')),
    );
    await tester.pump();
    expect(find.byType(ProjectHeader), findsOneWidget);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });
}
