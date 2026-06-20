/// `OpsProcessListItem` and `OpsStatusBar` — process list row with progress
/// bar and the bottom status strip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/src/apps/ops/theme/app_theme.dart'
    show buildOpsTheme;
import 'package:appplayer_studio/src/apps/ops/widgets/ops_models.dart';
import 'package:appplayer_studio/src/apps/ops/widgets/ops_process_list_item.dart';
import 'package:appplayer_studio/src/apps/ops/widgets/ops_status_bar.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildOpsTheme(),
  home: Scaffold(body: SizedBox(width: 400, height: 200, child: child)),
);

ProcessSummary _proc(ProcessRunState state, {double progress = 0.5}) =>
    ProcessSummary(
      id: 'proc-1',
      name: 'Ingestion',
      meta: 'every 6h · 4 steps',
      state: state,
      progress: progress,
    );

OpsStatusBarState _barState() => const OpsStatusBarState(
  connDot: Color(0xFF4FBE91),
  mcpServers: 3,
  facts: 120,
  patterns: 45,
  summaries: 12,
  llm: 'claude-sonnet-4-6',
  build: '0.4.3',
  tokensIn: 4200,
  tokensOut: 1100,
  llmCalls: 17,
  errors: 0,
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // ── OpsProcessListItem ───────────────────────────────────────────────────

  group('OpsProcessListItem', () {
    testWidgets('renders process name', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 200));
      await tester.pumpWidget(
        _wrap(
          OpsProcessListItem(
            process: _proc(ProcessRunState.running),
            selected: false,
            onTap: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Ingestion'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders meta text', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 200));
      await tester.pumpWidget(
        _wrap(
          OpsProcessListItem(
            process: _proc(ProcessRunState.ok),
            selected: false,
            onTap: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('every 6h · 4 steps'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('fires onTap when tapped', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 200));
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          OpsProcessListItem(
            process: _proc(ProcessRunState.running),
            selected: false,
            onTap: () => taps++,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(OpsProcessListItem));
      await tester.pumpAndSettle();
      expect(taps, 1);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('progress bar is present', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 200));
      await tester.pumpWidget(
        _wrap(
          OpsProcessListItem(
            process: _proc(ProcessRunState.running, progress: 0.65),
            selected: false,
            onTap: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders selected variant without crashing', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 200));
      await tester.pumpWidget(
        _wrap(
          OpsProcessListItem(
            process: _proc(ProcessRunState.running),
            selected: true,
            onTap: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(OpsProcessListItem), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('gate state renders without crashing', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 200));
      await tester.pumpWidget(
        _wrap(
          OpsProcessListItem(
            process: _proc(ProcessRunState.gate),
            selected: false,
            onTap: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('GATE'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('paused state shows "PAUSED" pill', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 200));
      await tester.pumpWidget(
        _wrap(
          OpsProcessListItem(
            process: _proc(ProcessRunState.paused),
            selected: false,
            onTap: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('PAUSED'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });
  });

  // ── OpsStatusBar ─────────────────────────────────────────────────────────
  // OpsStatusBar contains a Spacer() which needs a bounded Row width, so
  // unbounded-width wrappers do not work.  It overflows at typical test
  // viewports (~776px) because the content is designed for >=1280px screens.
  // We give the widget a guaranteed 2000px surface so the Row has enough room.

  group('OpsStatusBar', () {
    Widget _statusWrap(Widget child) =>
        MaterialApp(theme: buildOpsTheme(), home: Scaffold(body: child));

    testWidgets('renders MCP server count', (tester) async {
      await tester.binding.setSurfaceSize(const Size(2000, 60));
      await tester.pumpWidget(_statusWrap(OpsStatusBar(state: _barState())));
      await tester.pump();
      expect(find.textContaining('3 MCP servers'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders knowledge counts', (tester) async {
      await tester.binding.setSurfaceSize(const Size(2000, 60));
      await tester.pumpWidget(_statusWrap(OpsStatusBar(state: _barState())));
      await tester.pump();
      expect(find.textContaining('120 facts'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders llm label', (tester) async {
      await tester.binding.setSurfaceSize(const Size(2000, 60));
      await tester.pumpWidget(_statusWrap(OpsStatusBar(state: _barState())));
      await tester.pump();
      expect(find.textContaining('claude-sonnet-4-6'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('connectionTap fires callback', (tester) async {
      await tester.binding.setSurfaceSize(const Size(2000, 60));
      var taps = 0;
      await tester.pumpWidget(
        _statusWrap(
          OpsStatusBar(state: _barState(), onConnectionTap: () => taps++),
        ),
      );
      await tester.pump();
      await tester.tap(find.textContaining('3 MCP servers'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders token counts', (tester) async {
      await tester.binding.setSurfaceSize(const Size(2000, 60));
      await tester.pumpWidget(_statusWrap(OpsStatusBar(state: _barState())));
      await tester.pump();
      expect(find.textContaining('tok'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });
  });
}
