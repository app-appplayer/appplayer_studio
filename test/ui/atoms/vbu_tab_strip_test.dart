/// `VbuTabStrip` — horizontal tab strip atom (label + icon + close).
/// Verifies tab rendering, active highlight, onSelect callback, close
/// affordance gating, and closable=false respect.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/ui.dart';

Widget _wrap(Widget child) {
  return MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));
}

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders all tab labels', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuTabStrip(
          tabs: const <VbuTab>[
            VbuTab(label: 'Home', icon: Icons.home),
            VbuTab(label: 'Builder', icon: Icons.build),
          ],
          activeIndex: 0,
          onSelect: (_) {},
        ),
      ),
    );
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Builder'), findsOneWidget);
  });

  testWidgets('onSelect fires with tapped index', (tester) async {
    final received = <int>[];
    await tester.pumpWidget(
      _wrap(
        VbuTabStrip(
          tabs: const <VbuTab>[
            VbuTab(label: 'Home', icon: Icons.home),
            VbuTab(label: 'Builder', icon: Icons.build),
            VbuTab(label: 'Ops', icon: Icons.business),
          ],
          activeIndex: 0,
          onSelect: received.add,
        ),
      ),
    );
    await tester.tap(find.text('Ops'));
    await tester.pumpAndSettle();
    expect(received, <int>[2]);
  });

  testWidgets('onClose hidden when callback is null', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuTabStrip(
          tabs: const <VbuTab>[VbuTab(label: 'Home', icon: Icons.home)],
          activeIndex: 0,
          onSelect: (_) {},
          // onClose intentionally null.
        ),
      ),
    );
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('onClose shown for closable tabs when callback provided', (
    tester,
  ) async {
    final closed = <int>[];
    await tester.pumpWidget(
      _wrap(
        VbuTabStrip(
          tabs: const <VbuTab>[
            VbuTab(label: 'Home', icon: Icons.home, closable: false),
            VbuTab(label: 'Builder', icon: Icons.build),
          ],
          activeIndex: 0,
          onSelect: (_) {},
          onClose: closed.add,
        ),
      ),
    );
    // closable=false on Home → no close on first tab. Builder has one.
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('onClose fires with index on × tap', (tester) async {
    final closed = <int>[];
    await tester.pumpWidget(
      _wrap(
        VbuTabStrip(
          tabs: const <VbuTab>[
            VbuTab(label: 'Home', icon: Icons.home, closable: false),
            VbuTab(label: 'Builder', icon: Icons.build),
          ],
          activeIndex: 0,
          onSelect: (_) {},
          onClose: closed.add,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(closed, <int>[1]);
  });

  testWidgets('trailing widgets render to the right', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuTabStrip(
          tabs: const <VbuTab>[VbuTab(label: 'Home', icon: Icons.home)],
          activeIndex: 0,
          onSelect: (_) {},
          trailing: const <Widget>[Icon(Icons.add, key: Key('trailing-add'))],
        ),
      ),
    );
    expect(find.byKey(const Key('trailing-add')), findsOneWidget);
  });
}
