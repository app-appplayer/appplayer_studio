/// The project header's recent-projects menu reaches the user: the header
/// shows the chevron when it is given recents, and picking one opens it. The
/// shell used to build the header without the list and with a no-op pick,
/// so the menu never appeared.
library;

import 'dart:io';

import 'package:appplayer_studio/src/base/shell/project_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _header({
  List<String> recents = const [],
  ValueChanged<String>? onPick,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 320,
      child: ProjectHeader(
        projectName: 'p',
        dirty: false,
        canUndo: false,
        canRedo: false,
        onOpen: () {},
        onOpenRecent: onPick ?? (_) {},
        onSave: () {},
        onSaveAs: () {},
        onRevert: () {},
        onUndo: () {},
        onRedo: () {},
        onRename: () {},
        onCloseProject: () {},
        onHistory: () {},
        onSettings: () {},
        recentProjects: recents,
      ),
    ),
  ),
);

void main() {
  testWidgets('no recents → no chevron', (tester) async {
    await tester.pumpWidget(_header());
    expect(find.byTooltip('Recent projects'), findsNothing);
  });

  testWidgets('recents → chevron → pick opens that project', (tester) async {
    String? picked;
    await tester.pumpWidget(
      _header(recents: ['/w/calc', '/w/shop'], onPick: (p) => picked = p),
    );
    await tester.tap(find.byTooltip('Recent projects'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('shop').last);
    await tester.pumpAndSettle();
    expect(picked, '/w/shop');
  });

  test('the shell hands the active domain’s recents to the header', () {
    final src =
        File('lib/src/base/main/standard_studio_shell.dart').readAsStringSync();
    expect(src, contains('recentProjects:'));
    expect(src, contains('life.recentProjects'));
    expect(src, isNot(contains('onOpenRecent: (_) {}')));
  });

  testWidgets('disabled Undo still says why', (tester) async {
    await tester.pumpWidget(_header());
    expect(find.byTooltip('Nothing to undo'), findsOneWidget);
    expect(find.byTooltip('Nothing to redo'), findsOneWidget);
  });
}
