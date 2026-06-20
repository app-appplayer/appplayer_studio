/// Unit tests for `ChromeBridge` — the callback container chrome uses
/// to expose its UI actions over MCP. Covers default state of the
/// callback slots, ValueNotifier defaults, the internal-call flag /
/// helper landed in R24, and the theme-reinject tick channel.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';

void main() {
  group('ChromeBridge default state', () {
    test('callback slots are null until host wires them', () {
      final bridge = ChromeBridge();
      expect(bridge.toggleLeftPanel, isNull);
      expect(bridge.setLeftPanelVisible, isNull);
      expect(bridge.openSettings, isNull);
      expect(bridge.createNewPackage, isNull);
      expect(bridge.activatePackage, isNull);
      expect(bridge.dispatchLifecycle, isNull);
      expect(bridge.openAgents, isNull);
      expect(bridge.openSeed, isNull);
      expect(bridge.appendChatTurn, isNull);
    });

    test('inspectorEnabled defaults to false', () {
      final bridge = ChromeBridge();
      expect(bridge.inspectorEnabled.value, isFalse);
    });

    test('tabBarPeek defaults to false', () {
      final bridge = ChromeBridge();
      expect(bridge.tabBarPeek.value, isFalse);
    });

    test('toolsSubTab defaults to "tool"', () {
      final bridge = ChromeBridge();
      expect(bridge.toolsSubTab.value, equals('tool'));
    });

    test('themeReinjectTick starts at 0', () {
      final bridge = ChromeBridge();
      expect(bridge.themeReinjectTick.value, equals(0));
    });
  });

  group('DomainLifecycleState', () {
    test('empty constructor zeroes every flag', () {
      const state = DomainLifecycleState.empty();
      expect(state.hasProject, isFalse);
      expect(state.dirty, isFalse);
      expect(state.canUndo, isFalse);
      expect(state.canRedo, isFalse);
      expect(state.canCompareChannels, isFalse);
      expect(state.projectName, isNull);
    });

    test('full constructor exposes every flag through getters', () {
      const state = DomainLifecycleState(
        hasProject: true,
        dirty: true,
        canUndo: true,
        canRedo: false,
        canCompareChannels: true,
        projectName: 'demo',
      );
      expect(state.hasProject, isTrue);
      expect(state.dirty, isTrue);
      expect(state.canUndo, isTrue);
      expect(state.canRedo, isFalse);
      expect(state.canCompareChannels, isTrue);
      expect(state.projectName, 'demo');
    });
  });

  group('ChromeBridge listener notification', () {
    test('inspectorEnabled notifies listeners on flip', () {
      final bridge = ChromeBridge();
      var hits = 0;
      bridge.inspectorEnabled.addListener(() => hits++);
      bridge.inspectorEnabled.value = true;
      expect(hits, 1);
      bridge.inspectorEnabled.value = false;
      expect(hits, 2);
    });

    test('themeReinjectTick can be bumped repeatedly', () {
      final bridge = ChromeBridge();
      final captured = <int>[];
      bridge.themeReinjectTick.addListener(
        () => captured.add(bridge.themeReinjectTick.value),
      );
      bridge.themeReinjectTick.value++;
      bridge.themeReinjectTick.value++;
      bridge.themeReinjectTick.value++;
      expect(captured, <int>[1, 2, 3]);
    });
  });

  group('Additional ValueNotifier defaults', () {
    test('tabBarVisible starts visible', () {
      expect(ChromeBridge().tabBarVisible.value, isTrue);
    });

    test('hasTabStrip starts false', () {
      expect(ChromeBridge().hasTabStrip.value, isFalse);
    });

    test('homeActive starts false', () {
      expect(ChromeBridge().homeActive.value, isFalse);
    });

    test('lifecycleState defaults to empty', () {
      final s = ChromeBridge().lifecycleState.value;
      expect(s.hasProject, isFalse);
      expect(s.dirty, isFalse);
      expect(s.projectName, isNull);
    });

    test('activeChatAgentId defaults to empty (host resolver writes it)', () {
      // Empty at construction by design — the host's `defaultChatAgentResolver`
      // writes the active tab's seed-manifest `role: manager` id before the
      // first chat send (see chrome_bridge.dart doc). An empty value means
      // "no manager wired yet", not a hard-coded `studio.manager`.
      expect(ChromeBridge().activeChatAgentId.value, equals(''));
    });

    test('chatSlashHints / headerActions default empty', () {
      final b = ChromeBridge();
      expect(b.chatSlashHints.value, isEmpty);
      expect(b.headerActions.value, isEmpty);
    });

    test(
      'titlebarText / statusbarText / bundleVersion / activeMcpUrl default empty',
      () {
        final b = ChromeBridge();
        expect(b.titlebarText.value, equals(''));
        expect(b.statusbarText.value, equals(''));
        expect(b.bundleVersion.value, equals(''));
        expect(b.activeMcpUrl.value, equals(''));
      },
    );

    test('activeTabKey defaults to null', () {
      expect(ChromeBridge().activeTabKey.value, isNull);
    });

    test('mutating notifiers propagates to listeners', () {
      final b = ChromeBridge();
      var hits = 0;
      b.activeChatAgentId.addListener(() => hits++);
      b.activeChatAgentId.value = 'builder.manager';
      expect(hits, 1);
      expect(b.activeChatAgentId.value, equals('builder.manager'));
    });
  });

  group('Host-wired callback slots', () {
    test('toggleLeftPanel slot returns the value the host computed', () {
      final bridge = ChromeBridge();
      var visible = false;
      bridge.toggleLeftPanel = () {
        visible = !visible;
        return visible;
      };
      expect(bridge.toggleLeftPanel!.call(), isTrue);
      expect(bridge.toggleLeftPanel!.call(), isFalse);
    });

    test('setLeftPanelVisible slot forwards the requested state', () {
      final bridge = ChromeBridge();
      bool? lastRequest;
      bridge.setLeftPanelVisible = (v) {
        lastRequest = v;
        return v;
      };
      expect(bridge.setLeftPanelVisible!.call(true), isTrue);
      expect(lastRequest, isTrue);
      expect(bridge.setLeftPanelVisible!.call(false), isFalse);
      expect(lastRequest, isFalse);
    });
  });
}
