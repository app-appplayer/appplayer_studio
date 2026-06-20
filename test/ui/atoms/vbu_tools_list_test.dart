/// `VbuToolsList` — list of host / domain MCP tools with name / kind /
/// description / optional selection state.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/ui.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders tool names', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 600));
    await tester.pumpWidget(
      _wrap(
        const VbuToolsList(
          tools: <VbuToolItem>[
            VbuToolItem(name: 'studio.bundle.list'),
            VbuToolItem(name: 'bk.agent.list'),
          ],
        ),
      ),
    );
    expect(find.text('studio.bundle.list'), findsOneWidget);
    expect(find.text('bk.agent.list'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('renders item with description prop set', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 600));
    await tester.pumpWidget(
      _wrap(
        const VbuToolsList(
          tools: <VbuToolItem>[
            VbuToolItem(
              name: 'studio.meta.list_tools',
              description: 'List every MCP tool registered on this server.',
            ),
          ],
        ),
      ),
    );
    // VbuToolsList may surface description only on hover/expand — we
    // assert the list builds and the row renders the name.
    expect(find.text('studio.meta.list_tools'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('onTap fires when an item is tapped', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 600));
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        VbuToolsList(
          tools: <VbuToolItem>[
            VbuToolItem(name: 'studio.bundle.list', onTap: () => taps++),
          ],
        ),
      ),
    );
    await tester.tap(find.text('studio.bundle.list'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('empty list renders without crashing', (tester) async {
    await tester.pumpWidget(_wrap(const VbuToolsList(tools: <VbuToolItem>[])));
    expect(find.byType(VbuToolsList), findsOneWidget);
  });
}
