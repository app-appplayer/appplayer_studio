/// About shows the workspace in use now, not the one the project booted
/// with (`OpsConfig.activeWorkspace`), which read `_system` while the rest of
/// the app worked in `project/qa-ws`.
library;

import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/state/providers.dart';
import 'package:appplayer_studio/src/apps/ops/ui/about/about_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Active workspace follows the live selection', (tester) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cfg = OpsConfig(
      version: 'test',
      appName: 'Ops',
      activeWorkspace: '_system',
      workspacesRoot: '/tmp/ws',
      llm: const LlmSettings.empty(),
      mcp: const McpSettings.defaults(),
      browser: const BrowserSettings.defaults(),
      storage: const StorageSettings(localKvPath: '/tmp/ws/.kv'),
      channel: const ChannelSettings.empty(),
      security: const SecuritySettings.defaults(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          opsConfigProvider.overrideWith((ref) => cfg),
          activeWorkspaceIdProvider.overrideWith((ref) => 'project/qa-ws'),
        ],
        child: const MaterialApp(home: Scaffold(body: AboutPage())),
      ),
    );
    await tester.pump();
    expect(find.text('project/qa-ws'), findsOneWidget);
    expect(find.text('_system'), findsNothing);
  });
}
