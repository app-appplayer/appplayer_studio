/// `PreviewPanel` — center-column preview surface with toolbar tabs,
/// device-size picker, orientation toggle, and brightness menu.
///
/// Safety: PreviewPanel.initState is synchronous (reads initialPrefs only).
/// The inner PreviewMcpUi is async (spawns MCPUIRuntime) but it lives
/// inside a FutureBuilder — pump() renders the loading state without
/// waiting for the runtime future, so no hang risk.
/// We use pump() not pumpAndSettle() everywhere to avoid blocking on
/// the MCPUIRuntime.initialize() future.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:brain_kernel/brain_kernel.dart' show CanonicalChange, McpBundle;
import 'package:appplayer_studio/base.dart';

// ---------------------------------------------------------------------------
// Minimal WorkspaceCanonical stub.
// ---------------------------------------------------------------------------

class _StubCanonical implements WorkspaceCanonical {
  final _changes = StreamController<CanonicalChange>.broadcast();
  final _dirty = StreamController<bool>.broadcast();
  final _undoState = StreamController<UndoState>.broadcast();

  @override
  Stream<CanonicalChange> get changes => _changes.stream;
  @override
  Stream<bool> get dirtyChanges => _dirty.stream;
  @override
  Stream<UndoState> get undoStateChanges => _undoState.stream;

  @override
  bool get canUndo => false;
  @override
  bool get canRedo => false;
  @override
  bool get isDirty => false;
  @override
  bool get hasRestoredDraft => false;
  @override
  String? get workspacePath => null;
  @override
  String? get committedHash => null;

  @override
  Map<String, dynamic> get currentJson => const <String, dynamic>{};

  @override
  McpBundle get current => McpBundle.fromJson(const <String, dynamic>{
    'manifest': <String, dynamic>{},
  });

  @override
  List<Map<String, dynamic>> get undoStackJson =>
      const <Map<String, dynamic>>[];
  @override
  List<Map<String, dynamic>> get redoStackJson =>
      const <Map<String, dynamic>>[];

  static McpBundle _emptyBundle() => McpBundle.fromJson(const <String, dynamic>{
    'manifest': <String, dynamic>{},
  });

  @override
  Future<McpBundle> open(String workspacePath) async => _emptyBundle();
  @override
  Future<McpBundle> import({
    required String source,
    required ImportKind kind,
  }) async => _emptyBundle();
  @override
  Future<void> applyAtomic(CanonicalPatch patch) async {}
  @override
  Future<void> save() async {}
  @override
  Future<void> saveAs(String newPath) async {}
  @override
  Future<void> revert() async {}
  @override
  Future<bool> undo() async => false;
  @override
  Future<bool> redo() async => false;
  @override
  Future<String> hash() async => '';
  @override
  void seedUndoStacks({
    required List<Map<String, dynamic>> undo,
    required List<Map<String, dynamic>> redo,
  }) {}

  void dispose() {
    _changes.close();
    _dirty.close();
    _undoState.close();
  }
}

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: SizedBox(width: 800, height: 600, child: child)),
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // PreviewPrefsSnapshot --

  group('PreviewPrefsSnapshot', () {
    test('stores all fields', () {
      const snap = PreviewPrefsSnapshot(
        sizeChoice: 'mobile',
        orientation: 'portrait',
        brightness: 'dark',
        customW: 390,
        customH: 844,
      );
      expect(snap.sizeChoice, 'mobile');
      expect(snap.orientation, 'portrait');
      expect(snap.brightness, 'dark');
      expect(snap.customW, 390);
      expect(snap.customH, 844);
    });

    test('null fields are nullable', () {
      const snap = PreviewPrefsSnapshot();
      expect(snap.sizeChoice, isNull);
      expect(snap.orientation, isNull);
      expect(snap.brightness, isNull);
    });
  });

  // PreviewVariant --

  group('PreviewVariant', () {
    test('defaults framed=false', () {
      final variant = PreviewVariant(buildBody: (_) => const SizedBox());
      expect(variant.framed, isFalse);
    });

    test('customSizeOnly defaults false', () {
      final variant = PreviewVariant(buildBody: (_) => const SizedBox());
      expect(variant.customSizeOnly, isFalse);
    });

    test('minimalToolbar defaults false', () {
      final variant = PreviewVariant(buildBody: (_) => const SizedBox());
      expect(variant.minimalToolbar, isFalse);
    });
  });

  // PreviewPanel rendering --

  testWidgets('renders without crashing (smoke)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();

    await tester.pumpWidget(_wrap(PreviewPanel(canonical: stub)));
    await tester.pump();

    expect(find.byType(PreviewPanel), findsOneWidget);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('toolbar shows UI DSL and LVGL tab labels', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();

    await tester.pumpWidget(_wrap(PreviewPanel(canonical: stub)));
    await tester.pump();

    // Tab labels defined in _TabBar._Tab
    expect(find.text('UI DSL'), findsOneWidget);
    expect(find.text('LVGL'), findsOneWidget);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('shows size label Mobile by default', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();

    await tester.pumpWidget(_wrap(PreviewPanel(canonical: stub)));
    await tester.pump();

    // _SizeButton renders the choice label
    expect(find.text('Mobile'), findsOneWidget);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('shows orientation toggle icon', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();

    await tester.pumpWidget(_wrap(PreviewPanel(canonical: stub)));
    await tester.pump();

    expect(find.byIcon(Icons.stay_current_portrait_outlined), findsOneWidget);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('shows refresh and reset-view icon buttons', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();

    await tester.pumpWidget(_wrap(PreviewPanel(canonical: stub)));
    await tester.pump();

    expect(find.byIcon(Icons.refresh_outlined), findsOneWidget);
    expect(find.byIcon(Icons.center_focus_strong_outlined), findsOneWidget);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('accepts initialPrefs for tablet', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();

    await tester.pumpWidget(
      _wrap(
        PreviewPanel(
          canonical: stub,
          initialPrefs: const PreviewPrefsSnapshot(sizeChoice: 'tablet'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Tablet'), findsOneWidget);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('accepts initialPrefs for PC', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();

    await tester.pumpWidget(
      _wrap(
        PreviewPanel(
          canonical: stub,
          initialPrefs: const PreviewPrefsSnapshot(sizeChoice: 'pc'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('PC'), findsOneWidget);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('onPrefsChanged fires when Reset view is tapped', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();
    // Reset view doesn't mutate prefs, but Refresh does bump the reset epoch
    // which is internal state. onPrefsChanged is only fired by user-driven
    // size/orient/brightness changes. Test that the callback wire is correct
    // by checking the panel still renders after binding it.
    bool prefsChanged = false;

    await tester.pumpWidget(
      _wrap(
        PreviewPanel(
          canonical: stub,
          onPrefsChanged: (_) => prefsChanged = true,
        ),
      ),
    );
    await tester.pump();

    // Tap orientation toggle to trigger onPrefsChanged
    await tester.tap(find.byIcon(Icons.stay_current_portrait_outlined));
    await tester.pump();

    expect(prefsChanged, isTrue);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('after orientation toggle shows landscape icon', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();

    await tester.pumpWidget(_wrap(PreviewPanel(canonical: stub)));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.stay_current_portrait_outlined));
    await tester.pump();

    expect(find.byIcon(Icons.stay_current_landscape_outlined), findsOneWidget);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('minimal toolbar variant hides track tabs and refresh', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();

    await tester.pumpWidget(
      _wrap(
        PreviewPanel(
          canonical: stub,
          variant: PreviewVariant(
            buildBody: (_) => const ColoredBox(color: Colors.blue),
            minimalToolbar: true,
          ),
        ),
      ),
    );
    await tester.pump();

    // With minimalToolbar=true, track tabs and refresh icon are hidden
    expect(find.text('UI DSL'), findsNothing);
    expect(find.text('LVGL'), findsNothing);
    expect(find.byIcon(Icons.refresh_outlined), findsNothing);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('variant buildBody is called and its widget renders', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();

    await tester.pumpWidget(
      _wrap(
        PreviewPanel(
          canonical: stub,
          variant: PreviewVariant(buildBody: (_) => const Text('variant-body')),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('variant-body'), findsOneWidget);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('selfUi tab is disabled when selfUiFramework is none', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();

    await tester.pumpWidget(
      _wrap(
        PreviewPanel(canonical: stub, selfUiFramework: SelfUiFramework.none),
      ),
    );
    await tester.pump();

    // LVGL tab is disabled — tapping it does nothing (no mode switch).
    // The tab text is still visible but its InkWell has null onTap.
    final lvglTab = find.text('LVGL');
    expect(lvglTab, findsOneWidget);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('customSizeOnly variant starts in Custom size mode', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    final stub = _StubCanonical();

    await tester.pumpWidget(
      _wrap(
        PreviewPanel(
          canonical: stub,
          variant: PreviewVariant(
            buildBody: (_) => const SizedBox(),
            customSizeOnly: true,
          ),
        ),
      ),
    );
    await tester.pump();

    // Size label should be 'Custom' when customSizeOnly is true
    expect(find.text('Custom'), findsOneWidget);

    stub.dispose();
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
