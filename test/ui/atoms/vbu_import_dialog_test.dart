/// `MbdPeek`, `ImportSelection`, `showImportSelectionDialog` —
/// selective import picker dialog. Tests data models and dialog open/close
/// cycle. The `_RenderedPreview` child is only spawned when `previewKey` is
/// set via user interaction — not triggered in these tests (previewKey stays
/// null). SAFE: no async I/O in initState for the tested paths.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

MbdPeek _emptyPeek() => MbdPeek(
  pages: <String, Map<String, dynamic>>{},
  templates: <String, Map<String, dynamic>>{},
  dashboard: null,
  theme: null,
);

MbdPeek _peekWithPages(List<String> pageIds) => MbdPeek(
  pages: <String, Map<String, dynamic>>{
    for (final id in pageIds)
      id: <String, dynamic>{
        'type': 'page',
        'content': <String, dynamic>{'type': 'container'},
      },
  },
  templates: <String, Map<String, dynamic>>{},
  dashboard: null,
  theme: null,
);

MbdPeek _peekWithAll() => MbdPeek(
  pages: <String, Map<String, dynamic>>{
    'home': <String, dynamic>{'type': 'page'},
  },
  templates: <String, Map<String, dynamic>>{
    'card': <String, dynamic>{'type': 'container'},
  },
  dashboard: <String, dynamic>{'content': <String, dynamic>{}},
  theme: <String, dynamic>{'mode': 'dark'},
  navigation: <String, dynamic>{'type': 'bottomBar'},
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // --- MbdPeek ---

  group('MbdPeek', () {
    test('isEmpty is true for empty peek', () {
      expect(_emptyPeek().isEmpty, isTrue);
    });

    test('isEmpty is false when pages present', () {
      expect(_peekWithPages(<String>['home']).isEmpty, isFalse);
    });

    test('isEmpty is false when theme is set', () {
      final peek = MbdPeek(
        pages: <String, Map<String, dynamic>>{},
        templates: <String, Map<String, dynamic>>{},
        dashboard: null,
        theme: <String, dynamic>{'mode': 'light'},
      );
      expect(peek.isEmpty, isFalse);
    });

    test('isEmpty is false when dashboard is set', () {
      final peek = MbdPeek(
        pages: <String, Map<String, dynamic>>{},
        templates: <String, Map<String, dynamic>>{},
        dashboard: <String, dynamic>{'content': <String, dynamic>{}},
        theme: null,
      );
      expect(peek.isEmpty, isFalse);
    });
  });

  // --- ImportSelection ---

  group('ImportSelection.everything', () {
    test('isPartial is false', () {
      expect(ImportSelection.everything().isPartial, isFalse);
    });

    test('replaceOnConflict is true', () {
      expect(ImportSelection.everything().replaceOnConflict, isTrue);
    });

    test('hasAnyPick is false (pages/templates empty)', () {
      final sel = ImportSelection.everything();
      expect(sel.hasAnyPick, isFalse);
    });
  });

  group('ImportSelection.partial', () {
    test('isPartial is true', () {
      final sel = ImportSelection.partial(
        pages: <String>{'home'},
        templates: <String>{},
        includeDashboard: false,
        replaceOnConflict: true,
      );
      expect(sel.isPartial, isTrue);
    });

    test('hasAnyPick is true when pages non-empty', () {
      final sel = ImportSelection.partial(
        pages: <String>{'home'},
        templates: <String>{},
        includeDashboard: false,
        replaceOnConflict: true,
      );
      expect(sel.hasAnyPick, isTrue);
    });

    test('hasAnyPick is false when all empty', () {
      final sel = ImportSelection.partial(
        pages: <String>{},
        templates: <String>{},
        includeDashboard: false,
        replaceOnConflict: false,
      );
      expect(sel.hasAnyPick, isFalse);
    });

    test('hasAnyPick is true when includeDashboard is true', () {
      final sel = ImportSelection.partial(
        pages: <String>{},
        templates: <String>{},
        includeDashboard: true,
        replaceOnConflict: true,
      );
      expect(sel.hasAnyPick, isTrue);
    });

    test('custom replaceOnConflict=false is preserved', () {
      final sel = ImportSelection.partial(
        pages: <String>{'home'},
        templates: <String>{},
        includeDashboard: false,
        replaceOnConflict: false,
      );
      expect(sel.replaceOnConflict, isFalse);
    });

    test('includeTheme and includeNavigation defaults to false', () {
      final sel = ImportSelection.partial(
        pages: <String>{},
        templates: <String>{},
        includeDashboard: false,
        replaceOnConflict: true,
      );
      expect(sel.includeTheme, isFalse);
      expect(sel.includeNavigation, isFalse);
    });
  });

  // --- Dialog rendering ---

  testWidgets('dialog opens and shows channel label', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    final completer = Completer<ImportSelection?>();

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  final result = showImportSelectionDialog(
                    context: ctx,
                    channelLabel: 'SERVING',
                    sourcePath: '/tmp/source.mbd',
                    peek: _emptyPeek(),
                    existingPageIds: <String>{},
                    existingTemplateIds: <String>{},
                    targetHasDashboard: false,
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

    expect(find.textContaining('SERVING'), findsAtLeastNWidgets(1));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('dialog shows source path', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showImportSelectionDialog(
                    context: ctx,
                    channelLabel: 'native',
                    sourcePath: '/projects/my-app.mbd',
                    peek: _emptyPeek(),
                    existingPageIds: <String>{},
                    existingTemplateIds: <String>{},
                    targetHasDashboard: false,
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    expect(find.text('/projects/my-app.mbd'), findsOneWidget);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('shows Everything and Pick options', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showImportSelectionDialog(
                    context: ctx,
                    channelLabel: 'serving',
                    sourcePath: '/tmp/x.mbd',
                    peek: _emptyPeek(),
                    existingPageIds: <String>{},
                    existingTemplateIds: <String>{},
                    targetHasDashboard: false,
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    expect(find.text('Everything'), findsOneWidget);
    expect(find.text('Pick items'), findsOneWidget);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('Cancel closes dialog and returns null', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    ImportSelection? result = ImportSelection.everything();

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () async {
                  result = await showImportSelectionDialog(
                    context: ctx,
                    channelLabel: 'serving',
                    sourcePath: '/tmp/x.mbd',
                    peek: _emptyPeek(),
                    existingPageIds: <String>{},
                    existingTemplateIds: <String>{},
                    targetHasDashboard: false,
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

  testWidgets('Apply in Everything mode returns everything selection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    ImportSelection? result;

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () async {
                  result = await showImportSelectionDialog(
                    context: ctx,
                    channelLabel: 'serving',
                    sourcePath: '/tmp/x.mbd',
                    peek: _emptyPeek(),
                    existingPageIds: <String>{},
                    existingTemplateIds: <String>{},
                    targetHasDashboard: false,
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.isPartial, isFalse);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('Pick items mode shows section headers', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showImportSelectionDialog(
                    context: ctx,
                    channelLabel: 'serving',
                    sourcePath: '/tmp/x.mbd',
                    peek: _peekWithAll(),
                    existingPageIds: <String>{},
                    existingTemplateIds: <String>{},
                    targetHasDashboard: false,
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    await tester.tap(find.text('Pick items'));
    await tester.pump();

    expect(find.textContaining('PAGES'), findsAtLeastNWidgets(1));
    expect(find.textContaining('TEMPLATES'), findsAtLeastNWidgets(1));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('page ids are listed in Pick mode', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showImportSelectionDialog(
                    context: ctx,
                    channelLabel: 'serving',
                    sourcePath: '/tmp/x.mbd',
                    peek: _peekWithPages(<String>['homepage', 'settings']),
                    existingPageIds: <String>{},
                    existingTemplateIds: <String>{},
                    targetHasDashboard: false,
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    await tester.tap(find.text('Pick items'));
    await tester.pump();

    expect(find.text('homepage'), findsAtLeastNWidgets(1));
    expect(find.text('settings'), findsAtLeastNWidgets(1));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('empty pick mode returns partial with no picks disabled', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () async {
                  await showImportSelectionDialog(
                    context: ctx,
                    channelLabel: 'serving',
                    sourcePath: '/tmp/x.mbd',
                    peek: _peekWithPages(<String>['home']),
                    existingPageIds: <String>{},
                    existingTemplateIds: <String>{},
                    targetHasDashboard: false,
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    // Switch to Pick without selecting anything — Apply should be disabled
    await tester.tap(find.text('Pick items'));
    await tester.pump();

    // Apply button is disabled when partial && !hasAny, so tapping it
    // should not close the dialog.
    final applyButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(applyButton.onPressed, isNull);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('conflict badge "exists" appears for colliding page ids', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showImportSelectionDialog(
                    context: ctx,
                    channelLabel: 'serving',
                    sourcePath: '/tmp/x.mbd',
                    peek: _peekWithPages(<String>['home']),
                    existingPageIds: <String>{'home'},
                    existingTemplateIds: <String>{},
                    targetHasDashboard: false,
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    await tester.tap(find.text('Pick items'));
    await tester.pump();

    // 'home' exists in target — should show "exists" badge
    expect(find.text('exists'), findsAtLeastNWidgets(1));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
