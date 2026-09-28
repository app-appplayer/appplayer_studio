/// Unit tests for `registerChromeTools` — the `studio.chrome.*` MCP
/// tools that drive [ChromeBridge] callback slots / ValueNotifiers.
/// Locked contract: every handler (a) returns the "shell not mounted"
/// error envelope when its bridge slot is unwired, (b) validates its
/// required args before touching the bridge, and (c) on the happy
/// path forwards args verbatim to the wired slot and reflects the
/// slot's return value / the bridge's resulting state in the JSON
/// envelope. `studio.chrome.create_package` additionally locks the
/// `internalGuard` rejection (external MCP dispatch is not UI-click
/// context) ahead of touching `bridge.createNewPackage`.
///
/// `studio.app.open`'s route-navigate branch needs a live mounted tab
/// (its navigate hook) — SKIPPED here per the "don't fake what needs a
/// live render" rule. The validation branches and the project-bind
/// branch are covered: the bind branch only reads the registry's active
/// app id, which a registry mount without a widget tree provides.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';
import 'package:appplayer_studio/src/apps/form_builder/form_builder_builtin.dart';
import 'package:appplayer_studio/src/apps/scene_builder/scene_builder_builtin.dart';

Future<Map<String, dynamic>> _call(
  mk.KernelServerHost boot,
  String name, [
  Map<String, dynamic> args = const <String, dynamic>{},
]) async {
  final result = await boot.callTool(name, args);
  final text = (result.content.first as mk.KernelTextContent).text;
  return jsonDecode(text) as Map<String, dynamic>;
}

Future<mk.KernelToolResult> _callRaw(
  mk.KernelServerHost boot,
  String name, [
  Map<String, dynamic> args = const <String, dynamic>{},
]) => boot.callTool(name, args);

void main() {
  late mk.KernelServerHost boot;
  late ChromeBridge bridge;

  setUp(() {
    boot = mk.InProcessKernelServerHost()..register();
    bridge = ChromeBridge();
    registerChromeTools(boot, bridge);
  });

  group('studio.chrome.toggle_left_panel', () {
    test('c1 unmounted slot returns error', () async {
      final r = await _callRaw(boot, 'studio.chrome.toggle_left_panel');
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['error'], 'shell not mounted yet');
    });

    test('c2 wired slot reflects host-computed toggle', () async {
      var visible = false;
      bridge.toggleLeftPanel = () {
        visible = !visible;
        return visible;
      };
      final first = await _call(boot, 'studio.chrome.toggle_left_panel');
      expect(first['visible'], isTrue);
      final second = await _call(boot, 'studio.chrome.toggle_left_panel');
      expect(second['visible'], isFalse);
    });
  });

  group('studio.chrome.set_left_panel', () {
    test('c3 unmounted slot returns error', () async {
      final r = await _callRaw(boot, 'studio.chrome.set_left_panel', {
        'visible': true,
      });
      expect(r.isError, isTrue);
    });

    test('c4 non-bool visible rejected once wired', () async {
      bridge.setLeftPanelVisible = (v) => v;
      final r = await _callRaw(boot, 'studio.chrome.set_left_panel', {
        'visible': 'yes',
      });
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['error'], 'visible must be boolean');
    });

    test('c5 wired slot forwards requested state', () async {
      bool? requested;
      bridge.setLeftPanelVisible = (v) {
        requested = v;
        return v;
      };
      final out = await _call(boot, 'studio.chrome.set_left_panel', {
        'visible': true,
      });
      expect(out['visible'], isTrue);
      expect(requested, isTrue);
    });
  });

  group('studio.chrome.set_tab_bar', () {
    test('c6 non-bool visible rejected', () async {
      final r = await _callRaw(boot, 'studio.chrome.set_tab_bar', {
        'visible': 1,
      });
      expect(r.isError, isTrue);
    });

    test('c7 valid visible sets tabBarVisible notifier', () async {
      final out = await _call(boot, 'studio.chrome.set_tab_bar', {
        'visible': false,
      });
      expect(out['visible'], isFalse);
      expect(bridge.tabBarVisible.value, isFalse);
    });
  });

  group('studio.chrome.peek_tab_bar', () {
    test('c8 non-bool on rejected', () async {
      final r = await _callRaw(boot, 'studio.chrome.peek_tab_bar', {'on': 1});
      expect(r.isError, isTrue);
    });

    test('c9 on:true peeks in immediately', () async {
      expect(bridge.tabBarPeek.value, isFalse);
      final out = await _call(boot, 'studio.chrome.peek_tab_bar', {'on': true});
      expect(out['peek'], isTrue);
      expect(bridge.tabBarPeek.value, isTrue);
    });

    test('c10 on:false schedules a delayed peek-out', () async {
      bridge.peekIn();
      expect(bridge.tabBarPeek.value, isTrue);
      final out = await _call(boot, 'studio.chrome.peek_tab_bar', {
        'on': false,
      });
      expect(out['peek'], isFalse);
      // Not cleared synchronously — peekOut() debounces 200ms.
      expect(bridge.tabBarPeek.value, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(bridge.tabBarPeek.value, isFalse);
    });
  });

  group('studio.chrome.create_package (internalGuard)', () {
    test('c11 rejected by default (external dispatch context)', () async {
      bridge.createNewPackage =
          ({String? name, String? parent, String? id}) async =>
              <String, dynamic>{'ok': true};
      final r = await _callRaw(boot, 'studio.chrome.create_package');
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['ok'], isFalse);
      expect(out['error'], contains('internal tool'));
      expect(out['error'], contains('studio.chrome.create_package'));
    });

    test('c12 internal context + unwired slot → shell not mounted', () async {
      bridge.internalCallsEnabled = true;
      final r = await _callRaw(boot, 'studio.chrome.create_package');
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['ok'], isFalse);
      expect(out['error'], 'shell not mounted');
    });

    test('c13 internal context + wired slot forwards name/parent/id', () async {
      bridge.internalCallsEnabled = true;
      String? capturedName, capturedParent, capturedId;
      bridge.createNewPackage = ({
        String? name,
        String? parent,
        String? id,
      }) async {
        capturedName = name;
        capturedParent = parent;
        capturedId = id;
        return <String, dynamic>{
          'ok': true,
          'mbdPath': '/tmp/x.mbd',
          'name': name,
          'namespace': id,
        };
      };
      final out = await _call(boot, 'studio.chrome.create_package', {
        'name': 'Demo',
        'parent': '/tmp/parent',
        'id': 'com.example.demo',
      });
      expect(out['ok'], isTrue);
      expect(out['mbdPath'], '/tmp/x.mbd');
      expect(capturedName, 'Demo');
      expect(capturedParent, '/tmp/parent');
      expect(capturedId, 'com.example.demo');
    });
  });

  group('studio.chrome.open_agents', () {
    test('c14 unmounted slot returns error', () async {
      final r = await _callRaw(boot, 'studio.chrome.open_agents');
      expect(r.isError, isTrue);
    });

    test('c15 wired slot invoked and acknowledged', () async {
      var called = false;
      bridge.openAgents = () async {
        called = true;
      };
      final out = await _call(boot, 'studio.chrome.open_agents');
      expect(out['ok'], isTrue);
      expect(called, isTrue);
    });
  });

  group('studio.chrome.open_onboarding', () {
    test('c16 unmounted slot returns error', () async {
      final r = await _callRaw(boot, 'studio.chrome.open_onboarding');
      expect(r.isError, isTrue);
    });

    test('c17 wired slot invoked and acknowledged', () async {
      var called = false;
      bridge.openOnboarding = () async {
        called = true;
      };
      final out = await _call(boot, 'studio.chrome.open_onboarding');
      expect(out['ok'], isTrue);
      expect(called, isTrue);
    });
  });

  group('studio.chrome.open_seed', () {
    test('c18 empty namespace rejected', () async {
      final r = await _callRaw(boot, 'studio.chrome.open_seed', {
        'namespace': '',
      });
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['error'], 'namespace required');
    });

    test('c19 unmounted slot returns error', () async {
      final r = await _callRaw(boot, 'studio.chrome.open_seed', {
        'namespace': 'app_builder',
      });
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['error'], 'shell not mounted');
    });

    test('c20 undeclared namespace surfaces friendly error', () async {
      bridge.openSeed = (ns) async => false;
      final r = await _callRaw(boot, 'studio.chrome.open_seed', {
        'namespace': 'nope',
      });
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['error'], 'seed "nope" not declared');
    });

    test('c21 declared namespace opens successfully', () async {
      String? requested;
      bridge.openSeed = (ns) async {
        requested = ns;
        return true;
      };
      final out = await _call(boot, 'studio.chrome.open_seed', {
        'namespace': 'app_builder',
      });
      expect(out['ok'], isTrue);
      expect(requested, 'app_builder');
    });
  });

  group('studio.chrome.reload_tab', () {
    test('c22 unmounted slot returns error', () async {
      final r = await _callRaw(boot, 'studio.chrome.reload_tab');
      expect(r.isError, isTrue);
    });

    test('c23 wired slot forwards explicit index', () async {
      int? captured = -99;
      bridge.reloadTab = (idx) => captured = idx;
      final out = await _call(boot, 'studio.chrome.reload_tab', {'index': 2});
      expect(out['ok'], isTrue);
      expect(captured, 2);
    });

    test('c24 wired slot forwards null when index omitted', () async {
      int? captured = -99;
      bridge.reloadTab = (idx) => captured = idx;
      final out = await _call(boot, 'studio.chrome.reload_tab');
      expect(out['ok'], isTrue);
      expect(captured, isNull);
    });
  });

  group('studio.chrome.select_tab', () {
    test('c25 unmounted slots return error', () async {
      final r = await _callRaw(boot, 'studio.chrome.select_tab', {'index': 0});
      expect(r.isError, isTrue);
    });

    test('c26 neither index nor key rejected once wired', () async {
      bridge.selectTab = (i) => i;
      bridge.listTabs = () => const <Map<String, dynamic>>[];
      final r = await _callRaw(boot, 'studio.chrome.select_tab');
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['error'], 'index (int) or key (string) required');
    });

    test('c27 selects by index and returns active + tabs snapshot', () async {
      bridge.selectTab = (i) => i;
      bridge.listTabs =
          () => const <Map<String, dynamic>>[
            {'key': 'home', 'name': 'Home'},
            {'key': '/a.mbd', 'name': 'A'},
          ];
      final out = await _call(boot, 'studio.chrome.select_tab', {'index': 1});
      expect(out['active'], 1);
      expect((out['tabs'] as List), hasLength(2));
    });

    test('c28 selects by key resolved against the live tab list', () async {
      bridge.selectTab = (i) => i;
      bridge.listTabs =
          () => const <Map<String, dynamic>>[
            {'key': 'home', 'name': 'Home'},
            {'key': '/a.mbd', 'name': 'A'},
          ];
      final out = await _call(boot, 'studio.chrome.select_tab', {
        'key': '/a.mbd',
      });
      expect(out['active'], 1);
    });

    test('c29 unknown key errors', () async {
      bridge.selectTab = (i) => i;
      bridge.listTabs =
          () => const <Map<String, dynamic>>[
            {'key': 'home', 'name': 'Home'},
          ];
      final r = await _callRaw(boot, 'studio.chrome.select_tab', {
        'key': 'missing',
      });
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['error'], 'key not found');
      expect(out['key'], 'missing');
    });

    test('c30 out-of-range index surfaces error', () async {
      bridge.selectTab = (i) => -1;
      bridge.listTabs = () => const <Map<String, dynamic>>[];
      final r = await _callRaw(boot, 'studio.chrome.select_tab', {'index': 9});
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['active'], -1);
      expect(out['error'], 'index out of range');
    });
  });

  group('studio.chrome.close_tab', () {
    test('c31 missing index rejected', () async {
      final r = await _callRaw(boot, 'studio.chrome.close_tab');
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['error'], 'index required (integer)');
    });

    test('c32 unmounted slot returns error', () async {
      final r = await _callRaw(boot, 'studio.chrome.close_tab', {'index': 1});
      expect(r.isError, isTrue);
    });

    test('c33 wired slot reports closed true on success', () async {
      bridge.closeTab = (i, {bool force = false}) => 0;
      final out = await _call(boot, 'studio.chrome.close_tab', {'index': 1});
      expect(out['active'], 0);
      expect(out['closed'], isTrue);
    });

    test('c34 wired slot reports closed false on -1', () async {
      bridge.closeTab = (i, {bool force = false}) => -1;
      final out = await _call(boot, 'studio.chrome.close_tab', {'index': 0});
      expect(out['active'], -1);
      expect(out['closed'], isFalse);
    });

    test('c34a a tab that raised a dialog is NOT reported closed', () async {
      // The defect this pins: a draft / edited tab shows a confirmation dialog
      // and stays open, but the slot returned the active index and the tool
      // answered `closed: true`. Every scripted teardown then believed the tab
      // was gone — and an MCP caller cannot answer a dialog to find out.
      bridge.closeTab = (i, {bool force = false}) => kCloseTabConfirmRequired;
      final r = await _callRaw(boot, 'studio.chrome.close_tab', {'index': 1});
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['closed'], isFalse);
      expect(out['reason'], 'confirmRequired');
      expect(out['suggestion'], contains('force'));
    });

    test('c34b force is passed through to the slot', () async {
      // Without this the escape hatch is unreachable: the tool would keep
      // asking for a prompt the caller has already decided to skip.
      bool? sawForce;
      bridge.closeTab = (i, {bool force = false}) {
        sawForce = force;
        return 0;
      };
      await _call(boot, 'studio.chrome.close_tab', {'index': 1, 'force': true});
      expect(sawForce, isTrue);

      sawForce = null;
      await _call(boot, 'studio.chrome.close_tab', {'index': 1});
      expect(sawForce, isFalse, reason: 'force must default to off');
    });
  });

  group('studio.chrome.list_tabs', () {
    test('c35 unmounted slot returns error', () async {
      final r = await _callRaw(boot, 'studio.chrome.list_tabs');
      expect(r.isError, isTrue);
    });

    test('c36 wired slot returns tabs snapshot', () async {
      bridge.listTabs =
          () => const <Map<String, dynamic>>[
            {'key': 'home', 'name': 'Home'},
          ];
      final out = await _call(boot, 'studio.chrome.list_tabs');
      expect((out['tabs'] as List), hasLength(1));
    });
  });

  group('studio.chrome.open_history / open_settings', () {
    test('c37 open_history unmounted returns error', () async {
      final r = await _callRaw(boot, 'studio.chrome.open_history');
      expect(r.isError, isTrue);
    });

    test('c38 open_history wired resolves opened:true', () async {
      var called = false;
      bridge.openHistory = () async => called = true;
      final out = await _call(boot, 'studio.chrome.open_history');
      expect(out['opened'], isTrue);
      expect(called, isTrue);
    });

    test('c39 open_settings unmounted returns error', () async {
      final r = await _callRaw(boot, 'studio.chrome.open_settings');
      expect(r.isError, isTrue);
    });

    test('c40 open_settings wired resolves opened:true', () async {
      var called = false;
      bridge.openSettings = () async => called = true;
      final out = await _call(boot, 'studio.chrome.open_settings');
      expect(out['opened'], isTrue);
      expect(called, isTrue);
    });
  });

  group('studio.app.open (validation branches only — see file header)', () {
    test('c41 empty app id rejected', () async {
      final r = await _callRaw(boot, 'studio.app.open', {'app': ''});
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['ok'], isFalse);
      expect(out['step'], 'open');
      expect(out['error'], contains('app (built-in id) required'));
    });

    test('c42 unmounted openSeed slot returns error', () async {
      final r = await _callRaw(boot, 'studio.app.open', {
        'app': 'form_builder',
      });
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['error'], 'shell not mounted');
    });

    test('c43 undeclared app id rejected', () async {
      bridge.openSeed = (app) async => false;
      final r = await _callRaw(boot, 'studio.app.open', {'app': 'nope'});
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['error'], contains('not declared'));
    });

    test('c44 bare open (no project/route) succeeds without touching '
        'BuiltInAppRegistry', () async {
      String? requested;
      bridge.openSeed = (app) async {
        requested = app;
        return true;
      };
      final out = await _call(boot, 'studio.app.open', {'app': 'form_builder'});
      expect(out['ok'], isTrue);
      expect(out['opened'], 'form_builder');
      expect(requested, 'form_builder');
      // No project/route requested → no BuiltInAppRegistry poll ran.
      expect(out.containsKey('projectBound'), isFalse);
      expect(out.containsKey('landed'), isFalse);
    });
  });

  group('studio.app.open project bind', () {
    const bundle = '/qa/form_builder_bundle';

    setUp(() {
      bridge.openSeed = (app) async => true;
      BuiltInAppRegistry.instance.mount(
        bundle,
        const FormBuilderBuiltInApp(),
        BuiltInAppContext(bundlePath: bundle, chromeBridge: bridge),
      );
      BuiltInAppRegistry.instance.setActivePath(bundle);
    });

    tearDown(() {
      BuiltInAppRegistry.instance.setActivePath(null);
      BuiltInAppRegistry.instance.unmount(bundle);
    });

    test('c45 a bind the built-in refuses is the failed step', () async {
      bridge.openProjectInActive =
          (path) async => <String, dynamic>{
            'ok': false,
            'error': 'Not a Form Builder project (project.formproj missing)',
          };
      final r = await _callRaw(boot, 'studio.app.open', {
        'app': 'form_builder',
        'project': '/qa/empty',
      });
      expect(r.isError, isTrue);
      final out =
          jsonDecode((r.content.first as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(out['ok'], isFalse);
      expect(out['step'], 'project');
      expect(out['error'], contains('project.formproj missing'));
      expect(out.containsKey('projectBound'), isFalse);
    });

    test(
      'c51 a tab switch binds through the new tab, not the one handing over',
      () async {
        const sceneBundle = '/qa/scene_builder_bundle';
        BuiltInAppRegistry.instance.mount(
          sceneBundle,
          const SceneBuilderBuiltInApp(),
          BuiltInAppContext(bundlePath: sceneBundle, chromeBridge: bridge),
        );
        addTearDown(() => BuiltInAppRegistry.instance.unmount(sceneBundle));
        BuiltInAppRegistry.instance.setActivePath(sceneBundle);
        final calls = <String>[];
        bridge.openProjectInActive = (path) async {
          calls.add('scene');
          return <String, dynamic>{'ok': true, 'projectPath': path};
        };
        // Like the host: the registry flips at once, the slot moves on the
        // frame the host's settle waits for.
        bridge.openSeed = (app) async {
          BuiltInAppRegistry.instance.setActivePath(bundle);
          return true;
        };
        bridge.settleTabSwitch = () async {
          bridge.openProjectInActive = (path) async {
            calls.add('form');
            return <String, dynamic>{
              'ok': false,
              'error': 'not a form project',
            };
          };
        };
        final r = await _callRaw(boot, 'studio.app.open', {
          'app': 'form_builder',
          'project': '/qa/empty',
        });
        expect(calls, <String>['form']);
        expect(r.isError, isTrue);
      },
    );

    test('c46 an accepted bind reports projectBound', () async {
      String? bound;
      bridge.openProjectInActive = (path) async {
        bound = path;
        return <String, dynamic>{'ok': true, 'projectPath': path};
      };
      final out = await _call(boot, 'studio.app.open', {
        'app': 'form_builder',
        'project': '/qa/form',
      });
      expect(out['ok'], isTrue);
      expect(out['projectBound'], '/qa/form');
      expect(bound, '/qa/form');
    });
  });

  group('studio.chrome.select_tab settle', () {
    test('c52 answers after the tab switch has settled', () async {
      final order = <String>[];
      bridge.listTabs =
          () => <Map<String, dynamic>>[
            <String, dynamic>{'key': 'home'},
            <String, dynamic>{'key': 'b'},
          ];
      bridge.selectTab = (i) {
        order.add('select');
        return i;
      };
      bridge.settleTabSwitch = () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('settled');
      };
      final out = await _call(boot, 'studio.chrome.select_tab', {'index': 1});
      order.add('answered');
      expect(out['active'], 1);
      expect(order, <String>['select', 'settled', 'answered']);
    });
  });

  group('activeProjectInfo slot', () {
    test('c47 host reader answers when no tab claims the slot', () {
      bridge.hostActiveProjectInfo =
          () => <String, dynamic>{'projectPath': 'host'};
      expect(bridge.activeProjectInfo!()['projectPath'], 'host');
    });

    test('c48 a tab releasing its tear-off falls back to the host reader', () {
      final tab = _InfoTab();
      bridge.hostActiveProjectInfo =
          () => <String, dynamic>{'projectPath': 'host'};
      bridge.activeProjectInfo = tab.report;
      expect(bridge.activeProjectInfo!()['projectPath'], 'tab');
      // The release check a tab runs on deactivate — a fresh tear-off of the
      // same method is equal to the stored one.
      if (bridge.activeProjectInfo == tab.report)
        bridge.activeProjectInfo = null;
      expect(bridge.activeProjectInfo!()['projectPath'], 'host');
    });

    test('c49 another tab\'s claim is not released', () {
      final mine = _InfoTab();
      final theirs = _InfoTab();
      bridge.activeProjectInfo = theirs.report;
      if (bridge.activeProjectInfo == mine.report)
        bridge.activeProjectInfo = null;
      expect(bridge.activeProjectInfo, theirs.report);
    });

    test('c50 built-in shells release tear-off slots by equality', () {
      // `identical` is false for two tear-offs of the same method, so a
      // release written with it never fires and the slot stays pinned to
      // a tab that is no longer active.
      final tearOff = RegExp(
        r'identical\(\s*[\w.]*(ProjectInActive|activeProjectInfo)\s*,\s*'
        r'_(adoptProject|reportProjectInfo|newSceneProject|closeProject|'
        r'reportActiveProjectInfo|studioCloseProject)\s*,?\s*\)',
      );
      for (final path in <String>[
        'lib/src/apps/app_builder/feat/shell_layout.dart',
        'lib/src/apps/scene_builder/feat/scene_shell.dart',
        'lib/src/apps/ops/ops_shell.dart',
        'lib/src/apps/form_builder/ui/form_shell.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(tearOff.hasMatch(src), isFalse, reason: path);
      }
      // Each slot is released on its own ownership — gating the others on
      // `newProjectInActive` left them pinned once the next tab claimed it.
      expect(
        File(
          'lib/src/apps/app_builder/feat/shell_layout.dart',
        ).readAsStringSync(),
        isNot(contains('} else if (identical(bridge.newProjectInActive, fn))')),
      );
    });
  });
}

class _InfoTab {
  Map<String, dynamic> report() => <String, dynamic>{'projectPath': 'tab'};
}
