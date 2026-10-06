/// The project header's system buttons follow the slots the domain wired
/// (bundle spec 06 §6.3.1: an unbound slot is greyed out), take the host's
/// wording, and host buttons sit in the system row apart from the domain's
/// icons. Without a slot set every button behaves as before.
library;

import 'package:appplayer_studio/src/base/shell/activity_bar.dart';
import 'package:appplayer_studio/src/base/shell/project_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> fired;

  Widget header({
    Set<String>? boundSlots,
    Map<String, String> slotLabels = const <String, String>{},
    List<HeaderAction> hostActions = const <HeaderAction>[],
  }) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 360,
        child: ProjectHeader(
          projectName: 'Notes',
          dirty: false,
          canUndo: true,
          canRedo: true,
          onNew: () => fired.add('new'),
          onOpen: () => fired.add('open'),
          onOpenRecent: (_) {},
          onSave: () => fired.add('save'),
          onSaveAs: () => fired.add('saveAs'),
          onRevert: () => fired.add('revert'),
          onUndo: () => fired.add('undo'),
          onRedo: () => fired.add('redo'),
          onRename: () => fired.add('rename'),
          onCloseProject: () => fired.add('close'),
          onHistory: () => fired.add('history'),
          onSettings: () => fired.add('settings'),
          boundSlots: boundSlots,
          slotLabels: slotLabels,
          hostActions: hostActions,
        ),
      ),
    ),
  );

  const icons = <String, IconData>{
    'new': Icons.add_circle_outlined,
    'open': Icons.folder_open_outlined,
    'save': Icons.save_outlined,
    'saveAs': Icons.save_as_outlined,
    'revert': Icons.restore_outlined,
    'close': Icons.close_outlined,
    'undo': Icons.undo_outlined,
    'redo': Icons.redo_outlined,
    'history': Icons.history_outlined,
  };

  Future<void> tapAll(WidgetTester tester) async {
    for (final icon in icons.values) {
      await tester.tap(find.byIcon(icon), warnIfMissed: false);
    }
    await tester.tap(find.text('Notes'), warnIfMissed: false);
  }

  setUp(() => fired = <String>[]);

  testWidgets('without a slot set every system button works', (tester) async {
    await tester.pumpWidget(header());
    await tapAll(tester);
    expect(fired, <String>[...icons.keys, 'rename']);
  });

  testWidgets('only wired slots are on; the rest stay in place, off', (
    tester,
  ) async {
    await tester.pumpWidget(
      header(boundSlots: const <String>{'project.save', 'edit.undo'}),
    );
    // Every system button keeps its place.
    for (final icon in icons.values) {
      expect(find.byIcon(icon), findsOneWidget);
    }
    await tapAll(tester);
    expect(fired, <String>['save', 'undo']);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
  });

  testWidgets('the host words the buttons', (tester) async {
    await tester.pumpWidget(
      header(
        boundSlots: const <String>{'project.new', 'project.open'},
        slotLabels: const <String, String>{
          'project.new': 'New app',
          'project.open': 'Install app',
        },
      ),
    );
    expect(find.byTooltip('New app'), findsOneWidget);
    expect(find.byTooltip('Install app'), findsOneWidget);
    expect(find.byTooltip('New project'), findsNothing);
  });

  testWidgets('host buttons sit in the system row next to Settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      header(
        hostActions: <HeaderAction>[
          HeaderAction(
            tooltip: 'Apps',
            icon: Icons.apps,
            onTap: () => fired.add('apps'),
          ),
        ],
      ),
    );
    final apps = tester.getCenter(find.byIcon(Icons.apps));
    final settings = tester.getCenter(find.byIcon(Icons.settings_outlined));
    expect(apps.dy, settings.dy);
    expect(apps.dx, lessThan(settings.dx));
    await tester.tap(find.byIcon(Icons.apps));
    expect(fired, <String>['apps']);
  });

  testWidgets('the collapsed bar follows the same slots and wording', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 800,
            child: ActivityBar(
              onExpand: () {},
              onNew: () => fired.add('new'),
              onOpen: () => fired.add('open'),
              onSave: () => fired.add('save'),
              onSaveAs: () => fired.add('saveAs'),
              onRevert: () => fired.add('revert'),
              onCloseProject: () => fired.add('close'),
              onSettings: () {},
              onUndo: () => fired.add('undo'),
              onRedo: () => fired.add('redo'),
              onHistory: () => fired.add('history'),
              dirty: false,
              hasProject: true,
              canUndo: true,
              canRedo: true,
              boundSlots: const <String>{'project.save'},
              slotLabels: const <String, String>{
                'project.new': 'New',
                'project.open': 'Open',
              },
            ),
          ),
        ),
      ),
    );
    for (final icon in icons.values) {
      await tester.tap(find.byIcon(icon), warnIfMissed: false);
    }
    expect(fired, <String>['save']);
    expect(find.byTooltip('New project'), findsNothing);
    expect(find.byTooltip('Open project folder'), findsNothing);
    expect(find.byTooltip('New'), findsOneWidget);
  });
}
