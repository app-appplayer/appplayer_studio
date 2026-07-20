/// `studio.settings.set` / `studio.settings.get` must operate on the RAW
/// settings.json map, never a schema round-trip (VibeSettings.load →
/// toJson). A round-trip drops every key the running binary's schema does
/// not know, so a set() from an older build silently wiped keys a newer
/// build wrote — the live 2026-07-15 incident where `discoveryMdns` was
/// eaten by the previous binary's settings.set. This guards both verbs.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/install/project_tools.dart';
import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';
import 'package:appplayer_studio/src/base/settings/vibe_settings.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Map<String, dynamic> _json(mk.KernelToolResult r) =>
    jsonDecode(r.content.whereType<mk.KernelTextContent>().first.text)
        as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late mk.InProcessKernelServerHost boot;
  late String toolId;
  late File settingsFile;

  setUp(() {
    boot = mk.InProcessKernelServerHost();
    // Unique throwaway toolId → its own ~/.config/<toolId>/settings.json.
    toolId = 'test_settings_unknown_${DateTime.now().microsecondsSinceEpoch}';
    settingsFile = File(VibeSettings.defaultPath(toolId));
    registerProjectTools(boot, ChromeBridge(), toolId: toolId);
  });

  tearDown(() {
    final dir = settingsFile.parent;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('set preserves a key the running schema does not know', () async {
    // A settings.json carrying a key VibeSettings has no field for — as if
    // written by a newer build (or hand-edited).
    settingsFile.parent.createSync(recursive: true);
    settingsFile.writeAsStringSync(jsonEncode(<String, dynamic>{
      'themeMode': 'dark',
      'futureFeatureFlag': 'keep-me',
    }));

    final r = await boot.callTool('studio.settings.set', <String, dynamic>{
      'key': 'themeMode',
      'value': 'light',
    });
    expect(_json(r)['ok'], isTrue);

    final onDisk =
        jsonDecode(settingsFile.readAsStringSync()) as Map<String, dynamic>;
    expect(onDisk['themeMode'], 'light', reason: 'the edit landed');
    expect(
      onDisk['futureFeatureFlag'],
      'keep-me',
      reason: 'the unknown key must survive the write',
    );
  });

  test('get reads an unknown key back from the raw file', () async {
    settingsFile.parent.createSync(recursive: true);
    settingsFile.writeAsStringSync(jsonEncode(<String, dynamic>{
      'futureFeatureFlag': 'visible',
    }));

    final r = await boot.callTool('studio.settings.get', <String, dynamic>{
      'key': 'futureFeatureFlag',
    });
    expect(_json(r)['value'], 'visible');
  });

  test('set backs up a corrupt file before rewriting', () async {
    settingsFile.parent.createSync(recursive: true);
    settingsFile.writeAsStringSync('{ this is not json');

    final r = await boot.callTool('studio.settings.set', <String, dynamic>{
      'key': 'themeMode',
      'value': 'dark',
    });
    expect(_json(r)['ok'], isTrue);
    // The rewrite is valid JSON with the new key...
    final onDisk =
        jsonDecode(settingsFile.readAsStringSync()) as Map<String, dynamic>;
    expect(onDisk['themeMode'], 'dark');
    // ...and a .corrupt-<ts> backup of the original was made.
    final backups = settingsFile.parent
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).contains('.corrupt-'))
        .toList();
    expect(backups, isNotEmpty, reason: 'corrupt original preserved');
  });
}
