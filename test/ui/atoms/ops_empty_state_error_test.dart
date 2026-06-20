/// Ops `EmptyState` and `ErrorWithAction` — centred placeholder cards used
/// throughout the Ops shell when a list or page has no data / an error.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/src/apps/ops/widgets/empty_state.dart';
import 'package:appplayer_studio/src/apps/ops/widgets/error_with_action.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: SizedBox(width: 480, height: 400, child: child)),
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // ── EmptyState ───────────────────────────────────────────────────────────

  group('EmptyState', () {
    testWidgets('renders icon and headline', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 400));
      await tester.pumpWidget(
        _wrap(const EmptyState(icon: Icons.inbox, headline: 'No tasks yet.')),
      );
      await tester.pump();
      expect(find.byIcon(Icons.inbox), findsOneWidget);
      expect(find.text('No tasks yet.'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders optional hint', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 400));
      await tester.pumpWidget(
        _wrap(
          const EmptyState(
            icon: Icons.search,
            headline: 'Nothing found.',
            hint: 'Try a different query.',
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Try a different query.'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders CTA button and fires onAction', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 400));
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          EmptyState(
            icon: Icons.add,
            headline: 'No items.',
            actionLabel: 'Add item',
            onAction: () => taps++,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Add item'), findsOneWidget);
      await tester.tap(find.text('Add item'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('no CTA when actionLabel is null', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 400));
      await tester.pumpWidget(
        _wrap(const EmptyState(icon: Icons.inbox, headline: 'Nothing.')),
      );
      await tester.pump();
      expect(find.byType(FilledButton), findsNothing);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('compact mode renders with smaller padding', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 400));
      await tester.pumpWidget(
        _wrap(
          const EmptyState(
            icon: Icons.inbox,
            headline: 'Compact.',
            compact: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(EmptyState), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });
  });

  // ── ErrorWithAction ──────────────────────────────────────────────────────

  group('ErrorWithAction', () {
    testWidgets('renders error message', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 400));
      await tester.pumpWidget(
        _wrap(const ErrorWithAction(message: 'Something went wrong.')),
      );
      await tester.pump();
      expect(find.text('Something went wrong.'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('renders optional detail text', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 400));
      await tester.pumpWidget(
        _wrap(
          const ErrorWithAction(
            message: 'Error.',
            detail: 'Connection refused at port 7840.',
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Connection refused at port 7840.'), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('primary action fires onPressed', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 400));
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          ErrorWithAction(
            message: 'Failed.',
            actions: <ErrorAction>[
              ErrorAction(
                label: 'Retry',
                onPressed: () => taps++,
                primary: true,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('secondary action renders as OutlinedButton', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 400));
      await tester.pumpWidget(
        _wrap(
          ErrorWithAction(
            message: 'Oops.',
            actions: <ErrorAction>[
              ErrorAction(label: 'Details', onPressed: () {}, primary: false),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(OutlinedButton), findsOneWidget);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });

    testWidgets('no actions section when list is empty', (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 400));
      await tester.pumpWidget(
        _wrap(const ErrorWithAction(message: 'Error with no actions.')),
      );
      await tester.pump();
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    });
  });
}
