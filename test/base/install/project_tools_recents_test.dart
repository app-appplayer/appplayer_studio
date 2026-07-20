/// `registerProjectTools` must record the MRU (recents) at the MCP choke
/// point: `studio.project.new` / `studio.project.open` call
/// `ChromeBridge.recordRecentProject` on success — regardless of which
/// per-app slot (`newProjectInActive` / `openProjectInActive`) actually
/// created/opened the project.
///
/// Regression for the MCP↔UI mirror gap: the per-built-in slot overrides
/// (app_builder / ops / form / scene) do not all bump recents, so an
/// MCP-driven `project.new` while a built-in tab was active never touched
/// the MRU. Recording at the tool boundary fixes it uniformly.
import 'dart:convert';

import 'package:appplayer_studio/src/base/install/project_tools.dart';
import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(mk.KernelToolResult r) =>
    jsonDecode(r.content.whereType<mk.KernelTextContent>().first.text)
        as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late mk.InProcessKernelServerHost boot;
  late ChromeBridge bridge;
  late List<String> recorded;

  setUp(() {
    boot = mk.InProcessKernelServerHost();
    recorded = <String>[];
    bridge = ChromeBridge()
      ..recordRecentProject = (path) async {
        recorded.add(path);
      };
    registerProjectTools(boot, bridge, toolId: 'test_studio');
  });

  test('project.new records the created path to recents', () async {
    bridge.newProjectInActive =
        ({required String name, required String parent}) async =>
            <String, dynamic>{'ok': true, 'projectPath': '$parent/$name'};

    final r = await boot.callTool('studio.project.new', <String, dynamic>{
      'name': 'demo',
      'parent': '/tmp/scratch',
    });
    expect(_json(r)['ok'], isTrue);
    expect(recorded, <String>['/tmp/scratch/demo']);
  });

  test('project.open records the opened path to recents', () async {
    bridge.openProjectInActive =
        (path) async => <String, dynamic>{'ok': true, 'projectPath': path};

    await boot.callTool('studio.project.open', <String, dynamic>{
      'path': '/tmp/scratch/existing',
    });
    expect(recorded, <String>['/tmp/scratch/existing']);
  });

  test('a failed project.new does not pollute recents', () async {
    bridge.newProjectInActive =
        ({required String name, required String parent}) async =>
            <String, dynamic>{'ok': false, 'error': 'boom'};

    await boot.callTool('studio.project.new', <String, dynamic>{
      'name': 'demo',
      'parent': '/tmp/scratch',
    });
    expect(recorded, isEmpty);
  });
}
