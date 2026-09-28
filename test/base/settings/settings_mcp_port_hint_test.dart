/// The MCP URL field's hint names this instance's port. It was hard-coded
/// to the release port 7830, so a debug instance (7840) pointed users at a
/// server that is not this one.
library;

import 'package:appplayer_studio/src/base/settings/settings_dialog.dart';
import 'package:appplayer_studio/src/base/settings/vibe_settings.dart';
import 'package:appplayer_studio/src/main/vibe_studio_host_app.dart'
    show kStudioModelCatalog;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('hint shows the given port', (tester) async {
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
                      () => showVibeSettingsDialog(
                        context,
                        VibeSettings(llmModel: kStudioModelCatalog.first.id),
                        modelOptions: kStudioModelCatalog,
                        settingsPath: '/tmp/settings.json',
                        mcpPort: 7840,
                      ),
                  child: const Text('open'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.text('http://localhost:7840 — restart required'),
      findsOneWidget,
    );
    expect(find.textContaining('7830'), findsNothing);
  });
}
