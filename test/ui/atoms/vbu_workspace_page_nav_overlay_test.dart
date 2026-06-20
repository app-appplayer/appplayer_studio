/// `WorkspacePageNavOverlay` — floating draggable nav strip with pill
/// per router case, mint accent on active route.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: SizedBox(width: 800, height: 600, child: child)),
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders a pill per entry', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        WorkspacePageNavOverlay(
          entries: const <WorkspacePageNavEntry>[
            WorkspacePageNavEntry(route: '/home', label: 'Home'),
            WorkspacePageNavEntry(route: '/about', label: 'About'),
            WorkspacePageNavEntry(route: '/contact', label: 'Contact'),
          ],
          activeRoute: '/home',
          onNavigate: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    expect(find.text('Contact'), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('fires onNavigate with the tapped route', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    String? navigated;
    await tester.pumpWidget(
      _wrap(
        WorkspacePageNavOverlay(
          entries: const <WorkspacePageNavEntry>[
            WorkspacePageNavEntry(route: '/home', label: 'Home'),
            WorkspacePageNavEntry(route: '/settings', label: 'Settings'),
          ],
          activeRoute: '/home',
          onNavigate: (r) => navigated = r,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(navigated, '/settings');
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('renders drag handle icon', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        WorkspacePageNavOverlay(
          entries: const <WorkspacePageNavEntry>[
            WorkspacePageNavEntry(route: '/home', label: 'Home'),
          ],
          activeRoute: '/home',
          onNavigate: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('empty entry list renders without crashing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(
      _wrap(
        WorkspacePageNavOverlay(
          entries: const <WorkspacePageNavEntry>[],
          activeRoute: null,
          onNavigate: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WorkspacePageNavOverlay), findsOneWidget);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
  });
}
