/// `VbuMasterDetail` — left rail (sections of selectable items) + body
/// panel.
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

  testWidgets('renders section titles + item labels', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        const VbuMasterDetail(
          panelLabel: 'CATEGORIES',
          sections: <VbuMasterDetailSection>[
            VbuMasterDetailSection(
              title: 'workspace',
              items: <VbuMasterDetailItem>[
                VbuMasterDetailItem(label: 'home', icon: Icons.home),
                VbuMasterDetailItem(label: 'tasks', icon: Icons.task),
              ],
            ),
          ],
          body: Center(child: Text('detail body')),
        ),
      ),
    );
    expect(find.text('home'), findsOneWidget);
    expect(find.text('tasks'), findsOneWidget);
    expect(find.text('detail body'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('item onTap fires', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        VbuMasterDetail(
          panelLabel: 'X',
          sections: <VbuMasterDetailSection>[
            VbuMasterDetailSection(
              title: 'sec',
              items: <VbuMasterDetailItem>[
                VbuMasterDetailItem(
                  label: 'clickable',
                  icon: Icons.home,
                  onTap: () => taps++,
                ),
              ],
            ),
          ],
          body: const Text('body'),
        ),
      ),
    );
    await tester.tap(find.text('clickable'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('empty sections render with body only', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        const VbuMasterDetail(
          panelLabel: 'X',
          sections: <VbuMasterDetailSection>[],
          body: Text('empty body'),
        ),
      ),
    );
    expect(find.text('empty body'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
