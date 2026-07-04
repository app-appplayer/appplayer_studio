/// Organization directory (card master-detail): tree rows render, unit
/// collapse hides members, selection opens the property panel, and the
/// stats strip counts members/units/depth from the inputs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/ui/organization/org_chart_model.dart';
import 'package:appplayer_studio/src/apps/ops/ui/organization/org_directory.dart';

void main() {
  final inputs = [
    const OrgWsInput(
      id: 'org',
      title: 'HQ',
      type: 'org',
      leadMemberId: 'boss',
      agents: [
        OrgAgentInput(agentId: 'boss', memberId: 'boss', displayName: 'Boss'),
        OrgAgentInput(agentId: 'ana', memberId: 'ana', displayName: 'Ana'),
      ],
      processes: [
        OrgProcessInput(id: 'p1', title: 'Approval demo', steps: []),
      ],
    ),
    const OrgWsInput(
      id: 'org/fe',
      title: 'Frontend',
      type: 'project',
      parentId: 'org',
      agents: [
        OrgAgentInput(agentId: 'fe1', memberId: 'fe1', displayName: 'Fio'),
      ],
    ),
  ];

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: OrgDirectory(inputs: inputs)),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('tree renders units, members (lead first) and stats',
      (tester) async {
    await pump(tester);
    // Unit rows + nav rows.
    expect(find.text('HQ'), findsWidgets);
    expect(find.text('Frontend'), findsWidgets);
    // Member cards.
    expect(find.text('Boss'), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('Fio'), findsOneWidget);
    // Lead star on the lead card only.
    expect(find.byIcon(Icons.star), findsOneWidget);
    // Stats strip.
    expect(find.text('Members'), findsOneWidget);
    expect(find.text('3'), findsWidgets); // member total
    expect(find.text('Depth'), findsOneWidget);
    // Workflow listed in nav.
    expect(find.text('Approval demo'), findsOneWidget);
  });

  testWidgets('collapse hides the unit body (members + child units)',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pump();
    expect(find.text('Boss'), findsNothing);
    expect(find.text('Fio'), findsNothing); // nested unit collapsed too
  });

  testWidgets('member click opens the property panel with reporting chain',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('Fio'));
    await tester.pump();
    expect(find.text('Member'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    // Chain climbs to the parent unit's lead.
    expect(find.textContaining('Boss (HQ)'), findsOneWidget);
    // Close.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text('Save'), findsNothing);
  });

  testWidgets('workflow click shows the process summary', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Approval demo'));
    await tester.pump();
    expect(find.text('Workflow'), findsOneWidget);
    expect(find.text('Trigger'), findsOneWidget);
  });
}
