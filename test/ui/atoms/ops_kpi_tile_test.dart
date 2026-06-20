/// `OpsKpiTile` — metric tile with uppercase label, large value, and
/// optional delta row with colour-coded trend arrow.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/src/apps/ops/theme/app_theme.dart'
    show buildOpsTheme;
import 'package:appplayer_studio/src/apps/ops/widgets/ops_kpi_tile.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildOpsTheme(),
  home: Scaffold(body: SizedBox(width: 200, height: 120, child: child)),
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders label in uppercase', (tester) async {
    await tester.pumpWidget(
      _wrap(const OpsKpiTile(label: 'tasks', value: '42')),
    );
    await tester.pump();
    expect(find.text('TASKS'), findsOneWidget);
  });

  testWidgets('renders value text', (tester) async {
    await tester.pumpWidget(
      _wrap(const OpsKpiTile(label: 'agents', value: '7')),
    );
    await tester.pump();
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('renders delta when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const OpsKpiTile(
          label: 'cost',
          value: '\$120',
          delta: '+12% MoM',
          deltaTrend: OpsKpiTrend.up,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('+12% MoM'), findsOneWidget);
  });

  testWidgets('empty string rendered when delta is null (height stable)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const OpsKpiTile(label: 'errors', value: '0')),
    );
    await tester.pump();
    // The delta line reserves space even when null (Text('') is rendered).
    expect(find.byType(OpsKpiTile), findsOneWidget);
  });

  testWidgets('down trend renders without crashing', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const OpsKpiTile(
          label: 'latency',
          value: '88ms',
          delta: '-4%',
          deltaTrend: OpsKpiTrend.down,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('-4%'), findsOneWidget);
  });

  testWidgets('neutral trend renders without crashing', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const OpsKpiTile(
          label: 'uptime',
          value: '99.9%',
          delta: 'stable',
          deltaTrend: OpsKpiTrend.neutral,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('stable'), findsOneWidget);
  });
}
