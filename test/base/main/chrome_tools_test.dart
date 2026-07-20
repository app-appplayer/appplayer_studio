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
/// `studio.app.open`'s project-bind / route-navigate branches poll
/// `BuiltInAppRegistry.instance` (a real mounted built-in app + tab)
/// which needs a live widget tree — SKIPPED here per the "don't fake
/// what needs a live render" rule. Only the pre-registry-dependent
/// validation branches (empty app / shell not mounted / app not
/// declared / bare open) are covered.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

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
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
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
      final r = await _callRaw(
        boot,
        'studio.chrome.set_left_panel',
        {'visible': true},
      );
      expect(r.isError, isTrue);
    });

    test('c4 non-bool visible rejected once wired', () async {
      bridge.setLeftPanelVisible = (v) => v;
      final r = await _callRaw(
        boot,
        'studio.chrome.set_left_panel',
        {'visible': 'yes'},
      );
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['error'], 'visible must be boolean');
    });

    test('c5 wired slot forwards requested state', () async {
      bool? requested;
      bridge.setLeftPanelVisible = (v) {
        requested = v;
        return v;
      };
      final out = await _call(
        boot,
        'studio.chrome.set_left_panel',
        {'visible': true},
      );
      expect(out['visible'], isTrue);
      expect(requested, isTrue);
    });
  });

  group('studio.chrome.set_tab_bar', () {
    test('c6 non-bool visible rejected', () async {
      final r = await _callRaw(
        boot,
        'studio.chrome.set_tab_bar',
        {'visible': 1},
      );
      expect(r.isError, isTrue);
    });

    test('c7 valid visible sets tabBarVisible notifier', () async {
      final out = await _call(
        boot,
        'studio.chrome.set_tab_bar',
        {'visible': false},
      );
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
      final out = await _call(
        boot,
        'studio.chrome.peek_tab_bar',
        {'on': false},
      );
      expect(out['peek'], isFalse);
      // Not cleared synchronously — peekOut() debounces 200ms.
      expect(bridge.tabBarPeek.value, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(bridge.tabBarPeek.value, isFalse);
    });
  });

  group('studio.chrome.create_package (internalGuard)', () {
    test('c11 rejected by default (external dispatch context)', () async {
      bridge.createNewPackage = ({String? name, String? parent, String? id}) async =>
          <String, dynamic>{'ok': true};
      final r = await _callRaw(boot, 'studio.chrome.create_package');
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['ok'], isFalse);
      expect(out['error'], contains('internal tool'));
      expect(out['error'], contains('studio.chrome.create_package'));
    });

    test('c12 internal context + unwired slot → shell not mounted', () async {
      bridge.internalCallsEnabled = true;
      final r = await _callRaw(boot, 'studio.chrome.create_package');
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['ok'], isFalse);
      expect(out['error'], 'shell not mounted');
    });

    test('c13 internal context + wired slot forwards name/parent/id', () async {
      bridge.internalCallsEnabled = true;
      String? capturedName, capturedParent, capturedId;
      bridge.createNewPackage = ({String? name, String? parent, String? id}) async {
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
      final r = await _callRaw(boot, 'studio.chrome.open_seed', {'namespace': ''});
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['error'], 'namespace required');
    });

    test('c19 unmounted slot returns error', () async {
      final r = await _callRaw(
        boot,
        'studio.chrome.open_seed',
        {'namespace': 'app_builder'},
      );
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['error'], 'shell not mounted');
    });

    test('c20 undeclared namespace surfaces friendly error', () async {
      bridge.openSeed = (ns) async => false;
      final r = await _callRaw(
        boot,
        'studio.chrome.open_seed',
        {'namespace': 'nope'},
      );
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['error'], 'seed "nope" not declared');
    });

    test('c21 declared namespace opens successfully', () async {
      String? requested;
      bridge.openSeed = (ns) async {
        requested = ns;
        return true;
      };
      final out = await _call(
        boot,
        'studio.chrome.open_seed',
        {'namespace': 'app_builder'},
      );
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
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['error'], 'index (int) or key (string) required');
    });

    test('c27 selects by index and returns active + tabs snapshot', () async {
      bridge.selectTab = (i) => i;
      bridge.listTabs = () => const <Map<String, dynamic>>[
            {'key': 'home', 'name': 'Home'},
            {'key': '/a.mbd', 'name': 'A'},
          ];
      final out = await _call(boot, 'studio.chrome.select_tab', {'index': 1});
      expect(out['active'], 1);
      expect((out['tabs'] as List), hasLength(2));
    });

    test('c28 selects by key resolved against the live tab list', () async {
      bridge.selectTab = (i) => i;
      bridge.listTabs = () => const <Map<String, dynamic>>[
            {'key': 'home', 'name': 'Home'},
            {'key': '/a.mbd', 'name': 'A'},
          ];
      final out = await _call(
        boot,
        'studio.chrome.select_tab',
        {'key': '/a.mbd'},
      );
      expect(out['active'], 1);
    });

    test('c29 unknown key errors', () async {
      bridge.selectTab = (i) => i;
      bridge.listTabs = () => const <Map<String, dynamic>>[
            {'key': 'home', 'name': 'Home'},
          ];
      final r = await _callRaw(
        boot,
        'studio.chrome.select_tab',
        {'key': 'missing'},
      );
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['error'], 'key not found');
      expect(out['key'], 'missing');
    });

    test('c30 out-of-range index surfaces error', () async {
      bridge.selectTab = (i) => -1;
      bridge.listTabs = () => const <Map<String, dynamic>>[];
      final r = await _callRaw(boot, 'studio.chrome.select_tab', {'index': 9});
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['active'], -1);
      expect(out['error'], 'index out of range');
    });
  });

  group('studio.chrome.close_tab', () {
    test('c31 missing index rejected', () async {
      final r = await _callRaw(boot, 'studio.chrome.close_tab');
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['error'], 'index required (integer)');
    });

    test('c32 unmounted slot returns error', () async {
      final r = await _callRaw(boot, 'studio.chrome.close_tab', {'index': 1});
      expect(r.isError, isTrue);
    });

    test('c33 wired slot reports closed true on success', () async {
      bridge.closeTab = (i) => 0;
      final out = await _call(boot, 'studio.chrome.close_tab', {'index': 1});
      expect(out['active'], 0);
      expect(out['closed'], isTrue);
    });

    test('c34 wired slot reports closed false on -1', () async {
      bridge.closeTab = (i) => -1;
      final out = await _call(boot, 'studio.chrome.close_tab', {'index': 0});
      expect(out['active'], -1);
      expect(out['closed'], isFalse);
    });
  });

  group('studio.chrome.list_tabs', () {
    test('c35 unmounted slot returns error', () async {
      final r = await _callRaw(boot, 'studio.chrome.list_tabs');
      expect(r.isError, isTrue);
    });

    test('c36 wired slot returns tabs snapshot', () async {
      bridge.listTabs = () => const <Map<String, dynamic>>[
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
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['ok'], isFalse);
      expect(out['step'], 'open');
      expect(out['error'], contains('app (built-in id) required'));
    });

    test('c42 unmounted openSeed slot returns error', () async {
      final r = await _callRaw(boot, 'studio.app.open', {'app': 'form_builder'});
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['error'], 'shell not mounted');
    });

    test('c43 undeclared app id rejected', () async {
      bridge.openSeed = (app) async => false;
      final r = await _callRaw(boot, 'studio.app.open', {'app': 'nope'});
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['error'], contains('not declared'));
    });

    test(
      'c44 bare open (no project/route) succeeds without touching '
      'BuiltInAppRegistry',
      () async {
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
      },
    );
  });
}
