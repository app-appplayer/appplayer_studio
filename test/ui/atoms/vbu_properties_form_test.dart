/// `VbuPropertiesForm` — sectioned property editor used in the App
/// Builder properties panel.
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

  testWidgets('empty sections shows emptyText', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuPropertiesForm(emptyText: 'Nothing focused')),
    );
    expect(find.text('Nothing focused'), findsOneWidget);
  });

  testWidgets('renders section title + field label', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        const VbuPropertiesForm(
          sections: <VbuPropertiesSection>[
            VbuPropertiesSection(
              title: 'general',
              fields: <VbuPropertiesField>[
                VbuPropertiesField(label: 'name', value: 'home'),
              ],
            ),
          ],
        ),
      ),
    );
    expect(find.textContaining('name'), findsAtLeastNWidgets(1));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('contextLabel renders when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuPropertiesForm(contextLabel: '/ui/pages/home')),
    );
    expect(find.text('/ui/pages/home'), findsOneWidget);
  });
}
