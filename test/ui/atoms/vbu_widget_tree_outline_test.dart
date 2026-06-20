/// `VbuWidgetTreeOutline` — collapsible widget tree view (root nodes +
/// children + onSelect).
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

  testWidgets('renders root node labels', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuWidgetTreeOutline(
          root: <VbuWidgetTreeNode>[
            VbuWidgetTreeNode(id: 'app', label: 'Application'),
            VbuWidgetTreeNode(id: 'page', label: 'Home page'),
          ],
        ),
      ),
    );
    expect(find.text('Application'), findsOneWidget);
    expect(find.text('Home page'), findsOneWidget);
  });

  testWidgets('onSelect fires with tapped node id', (tester) async {
    String? selected;
    await tester.pumpWidget(
      _wrap(
        VbuWidgetTreeOutline(
          root: const <VbuWidgetTreeNode>[
            VbuWidgetTreeNode(id: 'a', label: 'Alpha'),
            VbuWidgetTreeNode(id: 'b', label: 'Beta'),
          ],
          onSelect: (id) => selected = id,
        ),
      ),
    );
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(selected, 'b');
  });

  testWidgets('empty root renders without crashing', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuWidgetTreeOutline(root: <VbuWidgetTreeNode>[])),
    );
    expect(find.byType(VbuWidgetTreeOutline), findsOneWidget);
  });

  testWidgets('children render only after parent is expanded', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuWidgetTreeOutline(
          root: <VbuWidgetTreeNode>[
            VbuWidgetTreeNode(
              id: 'parent',
              label: 'Parent',
              children: <VbuWidgetTreeNode>[
                VbuWidgetTreeNode(id: 'child', label: 'Child'),
              ],
            ),
          ],
        ),
      ),
    );
    // Default state is collapsed — child hidden.
    expect(find.text('Parent'), findsOneWidget);
    expect(find.text('Child'), findsNothing);
  });
}
