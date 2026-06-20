/// `ExportSelection` model + `showExportSelectionDialog` — channel export
/// picker dialog. Tests the data model, the "everything" fast path, and
/// the dialog open/close cycle through a [StatefulBuilder] (no initState
/// async I/O — SAFE for testWidgets).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

// ---------------------------------------------------------------------------
// Minimal LayerProjection backed by an empty JSON map.
// ---------------------------------------------------------------------------

LayerProjection _emptyProjection() =>
    LayerProjection.fromJson(const <String, dynamic>{});

LayerProjection _projectionWithPages(List<String> pageIds) {
  final pages = <String, dynamic>{
    for (final id in pageIds)
      id: <String, dynamic>{
        'type': 'page',
        'content': <String, dynamic>{'type': 'container'},
      },
  };
  return LayerProjection.fromJson(<String, dynamic>{
    'ui': <String, dynamic>{'pages': pages},
  });
}

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // --- ExportSelection model ---

  group('ExportSelection.everything', () {
    test('marks everything=true', () {
      final sel = ExportSelection.everything();
      expect(sel.everything, isTrue);
    });

    test('hasAnyPick is true for everything', () {
      final sel = ExportSelection.everything();
      expect(sel.hasAnyPick, isTrue);
    });

    test('pages/templates/assets are empty', () {
      final sel = ExportSelection.everything();
      expect(sel.pages, isEmpty);
      expect(sel.templates, isEmpty);
      expect(sel.assets, isEmpty);
    });
  });

  group('ExportSelection.partial', () {
    test('hasAnyPick is false with empty sets and no flags', () {
      final sel = ExportSelection.partial(
        pages: <String>{},
        templates: <String>{},
        assets: <String>{},
        includeDashboard: false,
        includeTheme: false,
        includeNavigation: false,
        includeManifestMeta: false,
      );
      expect(sel.hasAnyPick, isFalse);
    });

    test('hasAnyPick is true when pages is non-empty', () {
      final sel = ExportSelection.partial(
        pages: <String>{'home'},
        templates: <String>{},
        assets: <String>{},
        includeDashboard: false,
        includeTheme: false,
        includeNavigation: false,
      );
      expect(sel.hasAnyPick, isTrue);
    });

    test('hasAnyPick is true when includeDashboard is set', () {
      final sel = ExportSelection.partial(
        pages: <String>{},
        templates: <String>{},
        assets: <String>{},
        includeDashboard: true,
        includeTheme: false,
        includeNavigation: false,
      );
      expect(sel.hasAnyPick, isTrue);
    });

    test('hasAnyPick is true when includeManifestMeta is true (default)', () {
      final sel = ExportSelection.partial(
        pages: <String>{},
        templates: <String>{},
        assets: <String>{},
        includeDashboard: false,
        includeTheme: false,
        includeNavigation: false,
      );
      // includeManifestMeta defaults to true
      expect(sel.includeManifestMeta, isTrue);
      expect(sel.hasAnyPick, isTrue);
    });

    test('everything is false for partial', () {
      final sel = ExportSelection.partial(
        pages: <String>{'home'},
        templates: <String>{},
        assets: <String>{},
        includeDashboard: false,
        includeTheme: false,
        includeNavigation: false,
      );
      expect(sel.everything, isFalse);
    });
  });

  // --- Dialog rendering ---

  testWidgets('dialog opens and shows channel label', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    final completer = Completer<ExportSelection?>();

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  final result = showExportSelectionDialog(
                    context: ctx,
                    channelLabel: 'SERVING',
                    source: _emptyProjection(),
                  );
                  completer.complete(result);
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    // Dialog should contain the channel label
    expect(find.textContaining('SERVING'), findsAtLeastNWidgets(1));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('dialog shows Whole .mbd option selected by default', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showExportSelectionDialog(
                    context: ctx,
                    channelLabel: 'native',
                    source: _emptyProjection(),
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    expect(find.text('Whole .mbd'), findsOneWidget);
    expect(find.text('Pick'), findsOneWidget);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('Cancel closes the dialog and returns null', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    ExportSelection? result = ExportSelection.everything();

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () async {
                  result = await showExportSelectionDialog(
                    context: ctx,
                    channelLabel: 'serving',
                    source: _emptyProjection(),
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets(
    'Export button is enabled in everything mode and returns selection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      ExportSelection? result;

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder:
                (ctx) => ElevatedButton(
                  onPressed: () async {
                    result = await showExportSelectionDialog(
                      context: ctx,
                      channelLabel: 'serving',
                      source: _emptyProjection(),
                    );
                  },
                  child: const Text('Open'),
                ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pump();

      // Default is "everything" so Export should be enabled
      final exportButton = find.text('Export');
      expect(exportButton, findsOneWidget);
      await tester.tap(exportButton);
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.everything, isTrue);

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });
    },
  );

  testWidgets('switching to Pick mode shows section headers', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showExportSelectionDialog(
                    context: ctx,
                    channelLabel: 'serving',
                    source: _projectionWithPages(<String>['home', 'about']),
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    // Tap "Pick" radio row
    await tester.tap(find.text('Pick'));
    await tester.pump();

    // Section headers should appear
    expect(find.textContaining('PAGES'), findsAtLeastNWidgets(1));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('with pages, page ids appear in pick mode', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showExportSelectionDialog(
                    context: ctx,
                    channelLabel: 'serving',
                    source: _projectionWithPages(<String>['home', 'about']),
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    await tester.tap(find.text('Pick'));
    await tester.pump();

    expect(find.text('home'), findsAtLeastNWidgets(1));
    expect(find.text('about'), findsAtLeastNWidgets(1));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
