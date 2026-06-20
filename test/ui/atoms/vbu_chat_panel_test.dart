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

  testWidgets('seeded system turn renders italic system note', (tester) async {
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

  testWidgets('health bar renders in neutral state when snapshot is null', (
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
        ),
      ),
    );
    await tester.pump();
    // Neutral label "Health · —" present when no snapshot.
    expect(find.textContaining('Health'), findsOneWidget);
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
