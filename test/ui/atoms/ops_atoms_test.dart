/// Ops atom widgets: `OpsActorAvatar`, `OpsRoleTag`, `OpsLevelBars`,
/// `OpsStatusPill`, `OpsCard`, `OpsCardHeader`, `OpsCrumb`, `OpsDot`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/src/apps/ops/theme/app_theme.dart'
    show OpsStatus, buildOpsTheme;
import 'package:appplayer_studio/src/apps/ops/widgets/ops_atoms.dart';
import 'package:appplayer_studio/src/apps/ops/widgets/ops_models.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildOpsTheme(),
  home: Scaffold(body: SizedBox(width: 480, height: 400, child: child)),
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // ── OpsActorAvatar ───────────────────────────────────────────────────────

  group('OpsActorAvatar', () {
    const agentActor = ActivityActor(
      kind: ActorKind.agent,
      label: 'Research Bot',
    );
    const humanActor = ActivityActor(
      kind: ActorKind.human,
      label: 'Alice Wong',
    );

    testWidgets('renders initials of agent', (tester) async {
      await tester.pumpWidget(_wrap(const OpsActorAvatar(actor: agentActor)));
      await tester.pump();
      // Initials are R (first letter of "Research Bot" single-word last).
      // initials logic: ["Research", "Bot"] → "RB"
      expect(find.text('RB'), findsOneWidget);
    });

    testWidgets('renders initials of human', (tester) async {
      await tester.pumpWidget(_wrap(const OpsActorAvatar(actor: humanActor)));
      await tester.pump();
      expect(find.text('AW'), findsOneWidget);
    });

    testWidgets('online ring present when online=true', (tester) async {
      await tester.pumpWidget(
        _wrap(const OpsActorAvatar(actor: agentActor, size: 32, online: true)),
      );
      await tester.pump();
      // Stack has more children when online ring is drawn.
      final stack = tester.widget<Stack>(find.byType(Stack).first);
      expect(stack.children.length, greaterThan(1));
    });

    testWidgets('showInitials=false hides text', (tester) async {
      await tester.pumpWidget(
        _wrap(const OpsActorAvatar(actor: agentActor, showInitials: false)),
      );
      await tester.pump();
      expect(find.text('RB'), findsNothing);
    });
  });

  // ── OpsRoleTag ───────────────────────────────────────────────────────────

  group('OpsRoleTag', () {
    testWidgets('AI kind shows "AI"', (tester) async {
      await tester.pumpWidget(_wrap(const OpsRoleTag(kind: MemberKind.ai)));
      await tester.pump();
      expect(find.text('AI'), findsOneWidget);
    });

    testWidgets('human kind shows "HUMAN"', (tester) async {
      await tester.pumpWidget(_wrap(const OpsRoleTag(kind: MemberKind.human)));
      await tester.pump();
      expect(find.text('HUMAN'), findsOneWidget);
    });
  });

  // ── OpsLevelBars ─────────────────────────────────────────────────────────

  group('OpsLevelBars', () {
    testWidgets('renders three bar containers', (tester) async {
      await tester.pumpWidget(
        _wrap(const OpsLevelBars(levels: [0.2, 0.5, 0.8])),
      );
      await tester.pump();
      expect(find.byType(OpsLevelBars), findsOneWidget);
    });

    testWidgets('renders with empty list without crashing', (tester) async {
      await tester.pumpWidget(_wrap(const OpsLevelBars(levels: [])));
      await tester.pump();
      expect(find.byType(OpsLevelBars), findsOneWidget);
    });

    testWidgets('renders with fewer than three entries', (tester) async {
      await tester.pumpWidget(_wrap(const OpsLevelBars(levels: [1.0])));
      await tester.pump();
      expect(find.byType(OpsLevelBars), findsOneWidget);
    });
  });

  // ── OpsStatusPill ────────────────────────────────────────────────────────

  group('OpsStatusPill', () {
    testWidgets('renders label text', (tester) async {
      await tester.pumpWidget(
        _wrap(OpsStatusPill(status: OpsStatus.ok, label: 'done')),
      );
      await tester.pump();
      expect(find.text('done'), findsOneWidget);
    });

    testWidgets('pipeline factory done state shows "done"', (tester) async {
      await tester.pumpWidget(
        _wrap(OpsStatusPill.pipeline(PipelineState.done)),
      );
      await tester.pump();
      expect(find.text('done'), findsOneWidget);
    });

    testWidgets('pipeline factory gate state shows "GATE"', (tester) async {
      await tester.pumpWidget(
        _wrap(OpsStatusPill.pipeline(PipelineState.gate)),
      );
      await tester.pump();
      expect(find.text('GATE'), findsOneWidget);
    });

    testWidgets('process factory running state shows "RUN"', (tester) async {
      await tester.pumpWidget(
        _wrap(OpsStatusPill.process(ProcessRunState.running)),
      );
      await tester.pump();
      expect(find.text('RUN'), findsOneWidget);
    });

    testWidgets('compact flag renders without crashing', (tester) async {
      await tester.pumpWidget(
        _wrap(
          OpsStatusPill(
            status: OpsStatus.queued,
            label: 'queued',
            compact: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('queued'), findsOneWidget);
    });
  });

  // ── OpsCard ──────────────────────────────────────────────────────────────

  group('OpsCard', () {
    testWidgets('renders body', (tester) async {
      await tester.pumpWidget(
        _wrap(const OpsCard(body: Text('body content', key: Key('body')))),
      );
      await tester.pump();
      expect(find.byKey(const Key('body')), findsOneWidget);
    });

    testWidgets('renders header with title', (tester) async {
      await tester.pumpWidget(
        _wrap(
          OpsCard(
            header: const OpsCardHeader(title: 'My Card'),
            body: const Text('content'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('My Card'), findsOneWidget);
    });

    testWidgets('OpsCardHeader renders sub text', (tester) async {
      await tester.pumpWidget(
        _wrap(
          OpsCard(
            header: const OpsCardHeader(title: 'Card', sub: '42'),
            body: const Text('stuff'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('42'), findsOneWidget);
    });

    testWidgets('OpsCardHeader trailing widget visible', (tester) async {
      await tester.pumpWidget(
        _wrap(
          OpsCard(
            header: const OpsCardHeader(
              title: 'Card',
              trailing: Icon(Icons.star, key: Key('star')),
            ),
            body: const Text('content'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('star')), findsOneWidget);
    });

    testWidgets('no header renders body only without divider', (tester) async {
      await tester.pumpWidget(_wrap(const OpsCard(body: Text('no header'))));
      await tester.pump();
      expect(find.byType(Divider), findsNothing);
    });
  });

  // ── OpsCrumb ─────────────────────────────────────────────────────────────

  group('OpsCrumb', () {
    testWidgets('renders text in uppercase', (tester) async {
      await tester.pumpWidget(_wrap(const OpsCrumb('overview')));
      await tester.pump();
      expect(find.text('OVERVIEW'), findsOneWidget);
    });

    testWidgets('already-uppercase input is unaffected', (tester) async {
      await tester.pumpWidget(_wrap(const OpsCrumb('AGENTS')));
      await tester.pump();
      expect(find.text('AGENTS'), findsOneWidget);
    });
  });

  // ── OpsDot ───────────────────────────────────────────────────────────────

  group('OpsDot', () {
    testWidgets('renders without crashing (default size=6)', (tester) async {
      await tester.pumpWidget(
        _wrap(const Center(child: OpsDot(color: Colors.green))),
      );
      await tester.pump();
      expect(find.byType(OpsDot), findsOneWidget);
    });

    testWidgets('custom size renders without crashing', (tester) async {
      await tester.pumpWidget(
        _wrap(const Center(child: OpsDot(color: Colors.blue, size: 12))),
      );
      await tester.pump();
      expect(find.byType(OpsDot), findsOneWidget);
    });
  });
}
