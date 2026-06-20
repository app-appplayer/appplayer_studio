/// `OpsActivityRow`, `opsActivityHeadline`, and `OpsMemberRow` — list-row
/// atoms used in the Ops activity feed and member roster.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/src/apps/ops/theme/app_theme.dart'
    show buildOpsTheme;
import 'package:appplayer_studio/src/apps/ops/widgets/ops_activity_row.dart';
import 'package:appplayer_studio/src/apps/ops/widgets/ops_member_row.dart';
import 'package:appplayer_studio/src/apps/ops/widgets/ops_models.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildOpsTheme(),
  home: Scaffold(body: SizedBox(width: 480, height: 200, child: child)),
);

const _agentActor = ActivityActor(kind: ActorKind.agent, label: 'Builder Bot');

const _humanActor = ActivityActor(kind: ActorKind.human, label: 'Jin Park');

MemberSummary _aiMember() => const MemberSummary(
  actor: _agentActor,
  name: 'Builder Bot',
  subtitle: 'writer · active',
  kind: MemberKind.ai,
  online: true,
  layerProgress: [0.3, 0.6, 0.9],
);

MemberSummary _humanMember() => const MemberSummary(
  actor: _humanActor,
  name: 'Jin Park',
  subtitle: 'reviewer',
  kind: MemberKind.human,
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // ── OpsActivityRow ───────────────────────────────────────────────────────

  group('OpsActivityRow', () {
    testWidgets('renders meta text', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 200));
      await tester.pumpWidget(
        _wrap(
          OpsActivityRow(
            actor: _agentActor,
            headline: opsActivityHeadline(
              actorName: 'Builder Bot',
              verb: 'created',
            ),
            meta: '2 min ago',
          ),
        ),
      );
      await tester.pump();
      expect(find.text('2 min ago'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders actor name in headline', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 200));
      await tester.pumpWidget(
        _wrap(
          OpsActivityRow(
            actor: _humanActor,
            headline: opsActivityHeadline(
              actorName: 'Jin Park',
              verb: 'reviewed',
              ref: 'task-42',
            ),
            meta: '5h ago',
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Jin Park'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders without bottom border when isLast=true', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(480, 200));
      await tester.pumpWidget(
        _wrap(
          OpsActivityRow(
            actor: _agentActor,
            headline: opsActivityHeadline(actorName: 'Bot', verb: 'ran'),
            meta: 'now',
            isLast: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(OpsActivityRow), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });
  });

  // ── opsActivityHeadline ──────────────────────────────────────────────────

  group('opsActivityHeadline', () {
    test('includes actor name, verb, and ref', () {
      final span = opsActivityHeadline(
        actorName: 'Alice',
        verb: 'merged',
        ref: 'PR-17',
      );
      final children = span.children!;
      final texts =
          children.whereType<TextSpan>().map((s) => s.text ?? '').toList();
      final joined = texts.join('');
      expect(joined, contains('Alice'));
      expect(joined, contains('merged'));
      expect(joined, contains('PR-17'));
    });

    test('omits ref when null', () {
      final span = opsActivityHeadline(actorName: 'Bob', verb: 'approved');
      expect(span.children!.length, 2);
    });

    test('includes tag WidgetSpan when tag is provided', () {
      final span = opsActivityHeadline(
        actorName: 'Alice',
        verb: 'tagged',
        tag: 'v1.0',
      );
      expect(span.children!.whereType<WidgetSpan>().length, 1);
    });
  });

  // ── OpsMemberRow ─────────────────────────────────────────────────────────

  group('OpsMemberRow', () {
    testWidgets('renders member name', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 100));
      await tester.pumpWidget(_wrap(OpsMemberRow(member: _aiMember())));
      await tester.pump();
      expect(find.text('Builder Bot'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders AI role tag', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 100));
      await tester.pumpWidget(_wrap(OpsMemberRow(member: _aiMember())));
      await tester.pump();
      expect(find.text('AI'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders HUMAN role tag for human member', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 100));
      await tester.pumpWidget(_wrap(OpsMemberRow(member: _humanMember())));
      await tester.pump();
      expect(find.text('HUMAN'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('fires onTap when tapped', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 100));
      var taps = 0;
      await tester.pumpWidget(
        _wrap(OpsMemberRow(member: _aiMember(), onTap: () => taps++)),
      );
      await tester.pump();
      await tester.tap(find.byType(OpsMemberRow));
      await tester.pumpAndSettle();
      expect(taps, 1);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders subtitle text', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 100));
      await tester.pumpWidget(_wrap(OpsMemberRow(member: _aiMember())));
      await tester.pump();
      expect(find.text('writer · active'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });
  });
}
