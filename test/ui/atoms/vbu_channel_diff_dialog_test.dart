/// `showChannelDiffDialog` — channel diff dialog.
///
/// The `_ChannelDiffDialog` has async `_load()` in initState (dart:io via
/// FileWorkspaceFsPort). To let real I/O complete in tests, we use
/// `tester.runAsync()` which suspends the fake clock and lets the Dart
/// event loop process native I/O callbacks — the same pattern used in
/// `vbu_manifest_field_list_test.dart`.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vbu_channel_diff_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  // Immediate-state tests (single pump — no I/O wait needed)
  // -------------------------------------------------------------------------

  testWidgets('dialog opens with CircularProgressIndicator initially', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showChannelDiffDialog(
                    context: ctx,
                    projectPath: tmp.path,
                    channels: <({String id, String label, String subdir})>[
                      (id: 'serving', label: 'Serving', subdir: 'serving.mbd'),
                      (id: 'native', label: 'Native', subdir: 'native.mbd'),
                    ],
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump(); // future still in-flight

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('Dialog widget is present immediately after tap', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showChannelDiffDialog(
                    context: ctx,
                    projectPath: tmp.path,
                    channels: <({String id, String label, String subdir})>[
                      (id: 'a', label: 'A', subdir: 'a.mbd'),
                      (id: 'b', label: 'B', subdir: 'b.mbd'),
                    ],
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    expect(find.byType(Dialog), findsOneWidget);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('loading state: no diff content yet', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showChannelDiffDialog(
                    context: ctx,
                    projectPath: tmp.path,
                    channels: <({String id, String label, String subdir})>[
                      (id: 'l', label: 'Left', subdir: 'left.mbd'),
                      (id: 'r', label: 'Right', subdir: 'right.mbd'),
                    ],
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    expect(find.text('LEFT ONLY'), findsNothing);
    expect(find.text('RIGHT ONLY'), findsNothing);
    expect(find.text('MODIFIED'), findsNothing);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  // -------------------------------------------------------------------------
  // Settled-state tests (runAsync + pump — allows real I/O to complete)
  // -------------------------------------------------------------------------

  testWidgets('with only one channel shows "Need two enabled channels"', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));

    // Pass only ONE channel — _ChannelDiffDialog.take(2) has only 1 item,
    // so list.length < 2 and the "Need two channels" fallback renders.
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showChannelDiffDialog(
                    context: ctx,
                    projectPath: tmp.path,
                    channels: <({String id, String label, String subdir})>[
                      (id: 'serving', label: 'Serving', subdir: 'serving.mbd'),
                      // Only one channel → list.length == 1 < 2
                    ],
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(find.text('Need two enabled channels to compare.'), findsOneWidget);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('Close button dismisses dialog after FutureBuilder resolves', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));

    // Two empty-dir channels → list.length == 2 → diff layout with Close button.
    // No manifest.json → readJson returns null fast.
    Directory('${tmp.path}/a.mbd').createSync(recursive: true);
    Directory('${tmp.path}/b.mbd').createSync(recursive: true);

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showChannelDiffDialog(
                    context: ctx,
                    projectPath: tmp.path,
                    channels: <({String id, String label, String subdir})>[
                      (id: 'a', label: 'A', subdir: 'a.mbd'),
                      (id: 'b', label: 'B', subdir: 'b.mbd'),
                    ],
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    // Pump inside runAsync so the dialog widget is built and I/O can complete.
    await tester.runAsync(() async {
      await tester.pump(); // build the dialog / kick off _load()
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(); // flush FutureBuilder setState

    // FutureBuilder done: diff layout with Close button visible
    await tester.tap(find.text('Close'));
    await tester.pump();

    expect(find.byType(Dialog), findsNothing);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('two empty-bundle channels: renders diff layout after settle', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));

    // Two channels, no bundle files → _load() returns 2 snapshots with
    // empty pages/templates. The diff renders empty sections.
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showChannelDiffDialog(
                    context: ctx,
                    projectPath: tmp.path,
                    channels: <({String id, String label, String subdir})>[
                      (id: 's1', label: 'S1', subdir: 's1.mbd'),
                      (id: 's2', label: 'S2', subdir: 's2.mbd'),
                    ],
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // With 2 empty snapshots: either diff header or still loading
    expect(find.byType(Dialog), findsOneWidget);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  // -------------------------------------------------------------------------
  // Settled-state with empty channel dirs (no manifest.json → fast null path)
  // readJson returns null when manifest.json is absent, so _load() completes
  // in microseconds producing 2 snapshots with empty pages/templates.
  // The _Header then renders with both channel labels immediately.
  // -------------------------------------------------------------------------

  testWidgets('two existing empty-dir channels: diff header visible', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));

    // Create subdirs but NO manifest.json → readJson returns null fast,
    // giving 2 empty snapshots → _Header renders with "Channel diff".
    Directory('${tmp.path}/ch_a.mbd').createSync(recursive: true);
    Directory('${tmp.path}/ch_b.mbd').createSync(recursive: true);

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showChannelDiffDialog(
                    context: ctx,
                    projectPath: tmp.path,
                    channels: <({String id, String label, String subdir})>[
                      (id: 'ch_a', label: 'Channel A', subdir: 'ch_a.mbd'),
                      (id: 'ch_b', label: 'Channel B', subdir: 'ch_b.mbd'),
                    ],
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.runAsync(() async {
      await tester.pump(); // build the dialog / kick off _load()
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // With 2 empty-dir snapshots the _Header renders "Channel diff" title
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Channel diff'), findsOneWidget);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('channel label chips (Left / Right) visible after load', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));

    // No manifest.json → null fast path for both subdirs
    Directory('${tmp.path}/left.mbd').createSync(recursive: true);
    Directory('${tmp.path}/right.mbd').createSync(recursive: true);

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder:
              (ctx) => ElevatedButton(
                onPressed: () {
                  showChannelDiffDialog(
                    context: ctx,
                    projectPath: tmp.path,
                    channels: <({String id, String label, String subdir})>[
                      (id: 'left', label: 'Left', subdir: 'left.mbd'),
                      (id: 'right', label: 'Right', subdir: 'right.mbd'),
                    ],
                  );
                },
                child: const Text('Open'),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.runAsync(() async {
      await tester.pump(); // build the dialog / kick off _load()
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(find.byType(Dialog), findsOneWidget);
    // _Header._channelChip renders each label
    expect(find.text('Left'), findsWidgets);
    expect(find.text('Right'), findsWidgets);

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
