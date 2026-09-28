// `studio.ui.drag` has to start a long-press drag, not only a plain one.
//
// The tool emitted pointer down, then moves 16ms apart, then up. A
// `Draggable` accepts that. A `LongPressDraggable` — the tree's nodes, a
// reorderable row — arms only after the pointer has stayed still past the
// long-press delay, and a move before that cancels it: the drop never fired,
// and the tool reported `{ok: true}` for a drag that did nothing. `holdMs`
// keeps the pointer down and still before the first move.
//
// Both directions are locked: with the hold the drop lands; without it the
// same gesture does not, so the default cannot quietly change meaning.

import 'package:appplayer_studio/src/base/install/ui_control_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<String>> pumpLongPressDrag(WidgetTester tester) async {
    final dropped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              LongPressDraggable<String>(
                data: 'leaf',
                feedback: const SizedBox(width: 40, height: 40),
                child: const SizedBox(
                  key: Key('source'),
                  width: 120,
                  height: 40,
                  child: Text('leaf'),
                ),
              ),
              const SizedBox(height: 80),
              DragTarget<String>(
                onAcceptWithDetails: (d) => dropped.add(d.data),
                builder:
                    (_, _, _) => const SizedBox(
                      key: Key('target'),
                      width: 120,
                      height: 40,
                      child: Text('group'),
                    ),
              ),
            ],
          ),
        ),
      ),
    );
    return dropped;
  }

  Future<void> drag(WidgetTester tester, {required int holdMs}) async {
    final from = tester.getCenter(find.byKey(const Key('source')));
    final to = tester.getCenter(find.byKey(const Key('target')));
    // Real timers: the long-press recognizer arms on wall-clock time, and the
    // synthesiser waits with a real delay.
    await tester.runAsync(() => dispatchDrag(from, to, 12, holdMs: holdMs));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('holdMs past the long-press delay lands the drop', (
    tester,
  ) async {
    final dropped = await pumpLongPressDrag(tester);
    await drag(tester, holdMs: 700);
    expect(dropped, ['leaf']);
  });

  testWidgets('no hold — the same gesture does not arm a LongPressDraggable', (
    tester,
  ) async {
    final dropped = await pumpLongPressDrag(tester);
    await drag(tester, holdMs: 0);
    expect(
      dropped,
      isEmpty,
      reason: 'a move before the delay cancels the long press',
    );
  });
}
