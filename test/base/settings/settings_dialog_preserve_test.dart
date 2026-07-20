/// Settings dialog Save must round-trip every field it does NOT manage —
/// settings.json is one file, so a Save that rebuilds the object from
/// dialog fields alone silently wipes recents, last project, chromium /
/// server shell paths, browser config, and the discovery section
/// (the pre-2026-07-14 defect this file guards against).
library;

import 'package:appplayer_studio/src/base/settings/settings_dialog.dart';
import 'package:appplayer_studio/src/base/settings/vibe_settings.dart';
import 'package:appplayer_studio/src/main/vibe_studio_host_app.dart'
    show kStudioModelCatalog;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Save preserves non-dialog fields (no silent wipe)',
      (tester) async {
    final initial = VibeSettings(
      workspaceDir: '/ws',
      llmModel: kStudioModelCatalog.first.id,
      recentProjects: ['/p/one', '/p/two'],
      lastProjectPath: '/p/one',
      domainLastProject: {'makemind_ops': '/p/one'},
      recentSearches: ['button'],
      chromiumPath: '/opt/chromium',
      serverShellPath: '/opt/shell',
      maxBrowserContexts: 4,
      browserUserAgent: 'StudioBot/1.0',
      chatPanelWidth: 321,
      discoveryMdns: true,
      discoveryAutoConnect: true,
      discoveryEnforceSignature: true,
      discoveryDirectoryConfig: {'host': 'ldap.test', 'baseDN': 'dc=test'},
    );

    VibeSettings? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showVibeSettingsDialog(
                  context,
                  initial,
                  modelOptions: kStudioModelCatalog,
                  settingsPath: '/tmp/settings.json',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    final r = result!;
    // Dialog-managed fields kept their values.
    expect(r.workspaceDir, '/ws');
    // Non-dialog fields survive Save untouched.
    expect(r.recentProjects, ['/p/one', '/p/two']);
    expect(r.lastProjectPath, '/p/one');
    expect(r.domainLastProject['makemind_ops'], '/p/one');
    expect(r.recentSearches, ['button']);
    expect(r.chromiumPath, '/opt/chromium');
    expect(r.serverShellPath, '/opt/shell');
    expect(r.maxBrowserContexts, 4);
    expect(r.browserUserAgent, 'StudioBot/1.0');
    expect(r.chatPanelWidth, 321);
    // Discovery section state round-trips through the dialog controls.
    expect(r.discoveryMdns, isTrue);
    expect(r.discoveryAutoConnect, isTrue);
    expect(r.discoveryEnforceSignature, isTrue);
    expect(r.discoveryDirectoryConfig?['host'], 'ldap.test');
  });

  testWidgets(
      'directory toggle reveals the LDAP config fields (hidden while off)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () {
                // ignore: unawaited_futures
                showVibeSettingsDialog(
                  context,
                  VibeSettings(llmModel: kStudioModelCatalog.first.id),
                  modelOptions: kStudioModelCatalog,
                  settingsPath: '/tmp/settings.json',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Directory host'), findsNothing);
    // Switch order in the Studio tab: Debug mode, then the discovery
    // sources (USB, Wi-Fi, BLE, directory), then auto-connect.
    final directoryToggle = find.byType(Switch).at(4);
    await tester.ensureVisible(directoryToggle);
    await tester.pumpAndSettle();
    await tester.tap(directoryToggle);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Directory host'));
    expect(find.text('Directory host'), findsOneWidget);
    expect(find.text('Base DN'), findsOneWidget);
    expect(find.text('Bind DN'), findsOneWidget);
  });

  testWidgets(
      'Require signed boards toggle flips discoveryEnforceSignature on Save',
      (tester) async {
    VibeSettings? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showVibeSettingsDialog(
                  context,
                  VibeSettings(llmModel: kStudioModelCatalog.first.id),
                  modelOptions: kStudioModelCatalog,
                  settingsPath: '/tmp/settings.json',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Require signed boards'), findsOneWidget);
    // Studio-tab switch order: Debug mode (0), the four discovery sources
    // (USB 1 · Wi-Fi 2 · BLE 3 · directory 4), auto-connect (5), then the
    // signature-enforcement toggle (6).
    final enforceToggle = find.byType(Switch).at(6);
    await tester.ensureVisible(enforceToggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(enforceToggle).value, isFalse); // default off
    await tester.tap(enforceToggle);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result?.discoveryEnforceSignature, isTrue);
  });
}
