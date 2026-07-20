/// `ChatPanel` — left-column chat panel with header, health bar, feed,
/// and composer. Tests cover sync-safe surface: rendering, empty-feed
/// text, slash chips, and turn bubble kinds.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: SizedBox(width: 400, height: 600, child: child)),
);

VibeChatController _controller() => VibeChatController(
  send: (_) async => ChatTurn(role: 'assistant', text: 'reply'),
);

const List<VibeModelOption> _models = <VibeModelOption>[
  VibeModelOption(id: 'model-a', label: 'Model A'),
];

Color _layerColor(Object? _) => Colors.blueGrey;
String? _layerLabel(Object _) => null;

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders Chat title in header', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    final ctrl = _controller();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(
      _wrap(
        ChatPanel(
          controller: ctrl,
          modelOptions: _models,
          layerColorBuilder: _layerColor,
          layerLabelBuilder: _layerLabel,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Chat'), findsOneWidget);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('empty feed shows no-patches placeholder', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    final ctrl = _controller();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(
      _wrap(
        ChatPanel(
          controller: ctrl,
          modelOptions: _models,
          layerColorBuilder: _layerColor,
          layerLabelBuilder: _layerLabel,
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('No patches yet'), findsOneWidget);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('seeded user turn renders as prompt bubble', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    final ctrl = _controller();
    addTearDown(ctrl.dispose);
    ctrl.seed(<ChatTurn>[ChatTurn(role: 'user', text: 'hello world')]);
    await tester.pumpWidget(
      _wrap(
        ChatPanel(
          controller: ctrl,
          modelOptions: _models,
          layerColorBuilder: _layerColor,
          layerLabelBuilder: _layerLabel,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('hello world'), findsOneWidget);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('seeded system turn renders a LEFT-aligned, upright system note '
      '(readable for long auto-reports — not centred/italic)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    final ctrl = _controller();
    addTearDown(ctrl.dispose);
    ctrl.seed(<ChatTurn>[ChatTurn(role: 'system', text: 'Project saved.')]);
    await tester.pumpWidget(
      _wrap(
        ChatPanel(
          controller: ctrl,
          modelOptions: _models,
          layerColorBuilder: _layerColor,
          layerLabelBuilder: _layerLabel,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Project saved.'), findsOneWidget);
    final note = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .firstWhere((w) => w.data == 'Project saved.');
    // A long completion report was unreadable centred + italicised; the note
    // is now left-aligned and upright, with meaning carried by a colour accent.
    expect(note.textAlign, TextAlign.left);
    expect(note.style?.fontStyle, isNot(FontStyle.italic));
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('slash hints render as chips when input is empty', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    final ctrl = _controller();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(
      _wrap(
        ChatPanel(
          controller: ctrl,
          modelOptions: _models,
          layerColorBuilder: _layerColor,
          layerLabelBuilder: _layerLabel,
          slashHints: const <ChatSlashHint>[
            ChatSlashHint('/health'),
            ChatSlashHint('/grade'),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.text('/health'), findsOneWidget);
    expect(find.text('/grade'), findsOneWidget);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('health bar is hidden when snapshot is null', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    final ctrl = _controller();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(
      _wrap(
        ChatPanel(
          controller: ctrl,
          modelOptions: _models,
          layerColorBuilder: _layerColor,
          layerLabelBuilder: _layerLabel,
        ),
      ),
    );
    await tester.pump();
    // No snapshot → the health pill is suppressed entirely. A permanent
    // "Health · —" pill read as broken for domains that never populate
    // build health (e.g. Ops), so `ChatPanel` only mounts `_HealthBar`
    // once `health != null` (ops-ux-audit P3.9).
    expect(find.textContaining('Health'), findsNothing);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('health bar shows "all green" on pass snapshot', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    final ctrl = _controller();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(
      _wrap(
        ChatPanel(
          controller: ctrl,
          modelOptions: _models,
          layerColorBuilder: _layerColor,
          layerLabelBuilder: _layerLabel,
          health: const <String, dynamic>{
            'status': 'pass',
            'summary': <String, dynamic>{},
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('all green'), findsOneWidget);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('turn count shown in header when turns present', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    final ctrl = _controller();
    addTearDown(ctrl.dispose);
    ctrl.seed(<ChatTurn>[
      ChatTurn(role: 'user', text: 'hi'),
      ChatTurn(role: 'assistant', text: 'hello'),
    ]);
    await tester.pumpWidget(
      _wrap(
        ChatPanel(
          controller: ctrl,
          modelOptions: _models,
          layerColorBuilder: _layerColor,
          layerLabelBuilder: _layerLabel,
        ),
      ),
    );
    await tester.pump();
    // Turn count "2" is rendered next to "Chat".
    expect(find.text('2'), findsOneWidget);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });

  testWidgets('composer text field present', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    final ctrl = _controller();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(
      _wrap(
        ChatPanel(
          controller: ctrl,
          modelOptions: _models,
          layerColorBuilder: _layerColor,
          layerLabelBuilder: _layerLabel,
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('vibe.chat.input')), findsOneWidget);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  });
}
