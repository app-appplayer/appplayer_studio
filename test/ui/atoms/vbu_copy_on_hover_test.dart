/// `VbuCopyOnHover` — wraps a child and surfaces copy / delete buttons
/// when the mouse hovers (chat bubble pattern).
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/ui.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders the child verbatim', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuCopyOnHover(text: 'hello', child: Text('hello'))),
    );
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('without hover the copy affordance is hidden', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuCopyOnHover(text: 'hi', child: Text('payload'))),
    );
    expect(find.byIcon(Icons.copy), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('hover surfaces the copy icon and copies on tap', (tester) async {
    String? lastClipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          lastClipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await tester.pumpWidget(
      _wrap(
        const VbuCopyOnHover(
          text: 'hello-world',
          child: SizedBox(width: 200, height: 80),
        ),
      ),
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(VbuCopyOnHover)));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.copy), findsOneWidget);
    await tester.tap(find.byIcon(Icons.copy), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(lastClipboard, 'hello-world');
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  });

  testWidgets('delete icon hidden when onDelete is null', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuCopyOnHover(
          text: 'x',
          child: SizedBox(width: 200, height: 80),
        ),
      ),
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(VbuCopyOnHover)));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('delete icon fires onDelete when supplied', (tester) async {
    var deletes = 0;
    await tester.pumpWidget(
      _wrap(
        VbuCopyOnHover(
          text: 'x',
          onDelete: () => deletes++,
          child: const SizedBox(width: 200, height: 80),
        ),
      ),
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(VbuCopyOnHover)));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(deletes, 1);
  });
}
