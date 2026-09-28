/// Project slots fall back to the host's handler when the active tab clears
/// its own. Built-in tabs set a slot while active and null it when they
/// deactivate; before the host fallback that null wiped the host's handler
/// for good, so `studio.project.close` answered "shell not mounted" on any
/// tab visited after a built-in.
library;

import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a tab handler overrides the host one; clearing it restores the host',
    () {
      final bridge = ChromeBridge();
      Map<String, dynamic> host() => <String, dynamic>{'by': 'host'};
      Map<String, dynamic> tab() => <String, dynamic>{'by': 'tab'};

      expect(bridge.closeProjectInActive, isNull);
      bridge.hostCloseProjectInActive = host;
      expect(bridge.closeProjectInActive!()['by'], 'host');

      bridge.closeProjectInActive = tab;
      expect(bridge.closeProjectInActive!()['by'], 'tab');

      // What a built-in does on deactivate.
      bridge.closeProjectInActive = null;
      expect(bridge.closeProjectInActive!()['by'], 'host');
    },
  );

  test('new and open slots fall back the same way', () async {
    final bridge = ChromeBridge();
    bridge.hostNewProjectInActive =
        ({required name, required parent}) async => <String, dynamic>{
          'by': 'host',
        };
    bridge.hostOpenProjectInActive =
        (path) async => <String, dynamic>{'by': 'host'};
    bridge.newProjectInActive =
        ({required name, required parent}) async => <String, dynamic>{
          'by': 'tab',
        };
    bridge.openProjectInActive = (path) async => <String, dynamic>{'by': 'tab'};
    expect(
      (await bridge.newProjectInActive!(name: 'a', parent: '/'))['by'],
      'tab',
    );
    expect((await bridge.openProjectInActive!('/a'))['by'], 'tab');

    bridge.newProjectInActive = null;
    bridge.openProjectInActive = null;
    expect(
      (await bridge.newProjectInActive!(name: 'a', parent: '/'))['by'],
      'host',
    );
    expect((await bridge.openProjectInActive!('/a'))['by'], 'host');
  });
}
