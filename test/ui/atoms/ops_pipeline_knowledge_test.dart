/// `OpsPipelineNode`, `OpsPipelineConnector`, and `OpsKnowledgeCard` —
/// pipeline step cards and knowledge entry tiles used in the Ops process
/// detail view and knowledge page.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/src/apps/ops/theme/app_theme.dart'
    show buildOpsTheme;
import 'package:appplayer_studio/src/apps/ops/widgets/ops_knowledge_card.dart';
import 'package:appplayer_studio/src/apps/ops/widgets/ops_models.dart';
import 'package:appplayer_studio/src/apps/ops/widgets/ops_pipeline_node.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildOpsTheme(),
  home: Scaffold(body: SizedBox(width: 600, height: 300, child: child)),
);

PipelineStep _step(PipelineState state) => PipelineStep(
  indexLabel: '01',
  name: 'Ingest',
  actorCaption: 'curator agent',
  description: 'Reads and normalises the source corpus.',
  state: state,
  timeLabel: '2 min ago',
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // ── OpsPipelineNode ──────────────────────────────────────────────────────

  group('OpsPipelineNode', () {
    testWidgets('renders step name', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 300));
      await tester.pumpWidget(
        _wrap(OpsPipelineNode(step: _step(PipelineState.done))),
      );
      await tester.pump();
      expect(find.text('Ingest'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders index label', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 300));
      await tester.pumpWidget(
        _wrap(OpsPipelineNode(step: _step(PipelineState.running))),
      );
      await tester.pump();
      expect(find.text('01'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders description', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 300));
      await tester.pumpWidget(
        _wrap(OpsPipelineNode(step: _step(PipelineState.done))),
      );
      await tester.pump();
      expect(find.textContaining('Reads and normalises'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('gate state shows Approve button', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 300));
      await tester.pumpWidget(
        _wrap(OpsPipelineNode(step: _step(PipelineState.gate))),
      );
      await tester.pump();
      expect(find.text('Approve'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('gate state shows Reject button', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 300));
      await tester.pumpWidget(
        _wrap(OpsPipelineNode(step: _step(PipelineState.gate))),
      );
      await tester.pump();
      expect(find.text('Reject'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('approve button fires onApprove', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 300));
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          OpsPipelineNode(
            step: _step(PipelineState.gate),
            onApprove: () => taps++,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('non-gate state hides Approve/Reject buttons', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 300));
      await tester.pumpWidget(
        _wrap(OpsPipelineNode(step: _step(PipelineState.done))),
      );
      await tester.pump();
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Reject'), findsNothing);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('pending state renders with reduced opacity', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 300));
      await tester.pumpWidget(
        _wrap(OpsPipelineNode(step: _step(PipelineState.pending))),
      );
      await tester.pump();
      final opacity = tester.widget<Opacity>(find.byType(Opacity).first);
      expect(opacity.opacity, lessThan(1.0));
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('time label is rendered', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 300));
      await tester.pumpWidget(
        _wrap(OpsPipelineNode(step: _step(PipelineState.done))),
      );
      await tester.pump();
      expect(find.text('2 min ago'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });
  });

  // ── OpsPipelineConnector ─────────────────────────────────────────────────

  group('OpsPipelineConnector', () {
    testWidgets('renders without crashing (default)', (tester) async {
      await tester.pumpWidget(_wrap(const OpsPipelineConnector()));
      await tester.pump();
      expect(find.byType(OpsPipelineConnector), findsOneWidget);
    });

    testWidgets('dim variant renders without crashing', (tester) async {
      await tester.pumpWidget(_wrap(const OpsPipelineConnector(dim: true)));
      await tester.pump();
      expect(find.byType(OpsPipelineConnector), findsOneWidget);
    });
  });

  // ── OpsKnowledgeCard ─────────────────────────────────────────────────────

  group('OpsKnowledgeCard', () {
    const _factEntry = KnowledgeEntry(
      kind: KnowledgeKind.fact,
      title: 'Go generics ship in 1.18',
      body: 'Type parameters enable reusable algorithms.',
      meta: 'curator · 1h ago',
    );

    testWidgets('renders knowledge title', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 200));
      await tester.pumpWidget(_wrap(OpsKnowledgeCard(entry: _factEntry)));
      await tester.pump();
      expect(find.text('Go generics ship in 1.18'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders body text', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 200));
      await tester.pumpWidget(_wrap(OpsKnowledgeCard(entry: _factEntry)));
      await tester.pump();
      expect(find.textContaining('Type parameters'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders kind label in uppercase', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 200));
      await tester.pumpWidget(_wrap(OpsKnowledgeCard(entry: _factEntry)));
      await tester.pump();
      expect(find.text('FACT'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('fires onTap when tapped', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 200));
      var taps = 0;
      await tester.pumpWidget(
        _wrap(OpsKnowledgeCard(entry: _factEntry, onTap: () => taps++)),
      );
      await tester.pump();
      await tester.tap(find.byType(OpsKnowledgeCard));
      await tester.pumpAndSettle();
      expect(taps, 1);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('pattern kind shows "PATTERN"', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 200));
      const patternEntry = KnowledgeEntry(
        kind: KnowledgeKind.pattern,
        title: 'Retry with backoff',
        body: 'Exponential backoff reduces thundering-herd risk.',
        meta: 'curator',
      );
      await tester.pumpWidget(_wrap(OpsKnowledgeCard(entry: patternEntry)));
      await tester.pump();
      expect(find.text('PATTERN'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });
  });
}
