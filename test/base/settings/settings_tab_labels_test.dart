/// The settings dialog names its two tabs from the host: the bundle tab and
/// the host's own tab. The host tab's secondary line is the host's name
/// (`appName`) — it was fixed to "AppPlayer Studio" for every host.
library;

import 'package:appplayer_studio/src/base/settings/settings_dialog.dart';
import 'package:appplayer_studio/src/base/settings/vibe_settings.dart';
import 'package:appplayer_studio/src/main/vibe_studio_host_app.dart'
    show kStudioModelCatalog;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _open(
  WidgetTester tester, {
  String? domainTabLabel,
  String? hostTabLabel,
  String appName = 'AppPlayer Studio',
  Set<SettingsHostSection>? hostSections,
}) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder:
            (context) => Center(
              child: ElevatedButton(
                onPressed:
                    () =>
                        domainTabLabel == null
                            ? showVibeSettingsDialog(
                              context,
                              VibeSettings(
                                llmModel: kStudioModelCatalog.first.id,
                              ),
                              modelOptions: kStudioModelCatalog,
                              settingsPath: '/tmp/settings.json',
                              appName: appName,
                              domain: const DomainSettingsPanel(name: 'Todo'),
                            )
                            : showVibeSettingsDialog(
                              context,
                              VibeSettings(
                                llmModel: kStudioModelCatalog.first.id,
                              ),
                              modelOptions: kStudioModelCatalog,
                              settingsPath: '/tmp/settings.json',
                              appName: appName,
                              domain: const DomainSettingsPanel(name: 'Todo'),
                              domainTabLabel: domainTabLabel,
                              hostTabLabel: hostTabLabel!,
                              hostSections: hostSections,
                            ),
                child: const Text('open'),
              ),
            ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('defaults stay Domain / Studio', (tester) async {
    await _open(tester);
    expect(find.text('Domain'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('AppPlayer Studio'), findsOneWidget);
  });

  testWidgets('a host names both tabs and its own secondary line', (
    tester,
  ) async {
    await _open(
      tester,
      domainTabLabel: 'App',
      hostTabLabel: 'System',
      appName: 'AppPlayer Workbench',
    );
    expect(find.text('App'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('AppPlayer Workbench'), findsOneWidget);
    expect(find.text('Studio'), findsNothing);
    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    expect(find.text('System Settings'), findsOneWidget);
  });

  testWidgets('a host picks the built-in sections of its tab', (tester) async {
    await _open(
      tester,
      domainTabLabel: 'App',
      hostTabLabel: 'System',
      hostSections: const <SettingsHostSection>{
        SettingsHostSection.appearance,
        SettingsHostSection.mcpServer,
      },
    );
    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('MCP SERVER'), findsOneWidget);
    expect(find.text('WORKSPACE'), findsNothing);
    expect(find.text('AUTOSAVE'), findsNothing);
    expect(find.text('AUTO DISCOVERY'), findsNothing);
    expect(find.text('DEBUG MODE'), findsNothing);
    // Always shown.
    expect(find.text('API PROVIDERS'), findsOneWidget);
  });

  testWidgets('without a selection every section shows (Studio)', (
    tester,
  ) async {
    await _open(tester);
    await tester.tap(find.text('Studio'));
    await tester.pumpAndSettle();
    expect(find.text('WORKSPACE'), findsOneWidget);
    expect(find.text('AUTOSAVE'), findsOneWidget);
  });
}
