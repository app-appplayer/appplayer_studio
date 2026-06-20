/// Unit tests for `ChromeBridge` value types and state notifiers that
/// are pure-logic (no UI / no live shell):
///
///   cb1  DomainLifecycleState.empty() — all false, projectName null
///   cb2  DomainLifecycleState.home() — projectName 'Home', hasProject false
///   cb3  DomainLifecycleState full constructor — carries every field
///   cb4  ChromeBridge.tabBarVisible — default true, can be toggled
///   cb5  ChromeBridge.hasTabStrip — default false, can be set
///   cb6  ChromeBridge.homeActive — default false, can be set
///   cb7  ChromeBridge nullable slots default to null
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/main/chrome_bridge.dart';

void main() {
  // ---------------------------------------------------------------------------
  // cb1 — DomainLifecycleState.empty
  // ---------------------------------------------------------------------------
  group('cb1 DomainLifecycleState.empty', () {
    test('cb1 all bool fields are false, projectName is null', () {
      const s = DomainLifecycleState.empty();
      expect(s.hasProject, isFalse);
      expect(s.dirty, isFalse);
      expect(s.canUndo, isFalse);
      expect(s.canRedo, isFalse);
      expect(s.canCompareChannels, isFalse);
      expect(s.projectName, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // cb2 — DomainLifecycleState.home
  // ---------------------------------------------------------------------------
  group('cb2 DomainLifecycleState.home', () {
    test('cb2 projectName is "Home", hasProject is false', () {
      const s = DomainLifecycleState.home();
      expect(s.projectName, 'Home');
      expect(s.hasProject, isFalse);
      expect(s.dirty, isFalse);
      expect(s.canUndo, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // cb3 — DomainLifecycleState full constructor
  // ---------------------------------------------------------------------------
  group('cb3 DomainLifecycleState full constructor', () {
    test('cb3 carries every field', () {
      const s = DomainLifecycleState(
        hasProject: true,
        dirty: true,
        canUndo: true,
        canRedo: false,
        canCompareChannels: true,
        projectName: 'My Project',
      );
      expect(s.hasProject, isTrue);
      expect(s.dirty, isTrue);
      expect(s.canUndo, isTrue);
      expect(s.canRedo, isFalse);
      expect(s.canCompareChannels, isTrue);
      expect(s.projectName, 'My Project');
    });

    test('cb3 projectName optional (defaults null)', () {
      const s = DomainLifecycleState(
        hasProject: true,
        dirty: false,
        canUndo: false,
        canRedo: false,
        canCompareChannels: false,
      );
      expect(s.projectName, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // cb4 — ChromeBridge.tabBarVisible
  // ---------------------------------------------------------------------------
  group('cb4 tabBarVisible', () {
    test('cb4 defaults to true', () {
      final b = ChromeBridge();
      expect(b.tabBarVisible.value, isTrue);
    });

    test('cb4 can be set to false and back', () {
      final b = ChromeBridge();
      b.tabBarVisible.value = false;
      expect(b.tabBarVisible.value, isFalse);
      b.tabBarVisible.value = true;
      expect(b.tabBarVisible.value, isTrue);
    });

    test('cb4 notifies listeners on change', () {
      final b = ChromeBridge();
      var notified = false;
      b.tabBarVisible.addListener(() => notified = true);
      b.tabBarVisible.value = false;
      expect(notified, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // cb5 — ChromeBridge.hasTabStrip
  // ---------------------------------------------------------------------------
  group('cb5 hasTabStrip', () {
    test('cb5 defaults to false', () {
      final b = ChromeBridge();
      expect(b.hasTabStrip.value, isFalse);
    });

    test('cb5 can be flipped to true', () {
      final b = ChromeBridge();
      b.hasTabStrip.value = true;
      expect(b.hasTabStrip.value, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // cb6 — ChromeBridge.homeActive
  // ---------------------------------------------------------------------------
  group('cb6 homeActive', () {
    test('cb6 defaults to false', () {
      final b = ChromeBridge();
      expect(b.homeActive.value, isFalse);
    });

    test('cb6 can be set to true', () {
      final b = ChromeBridge();
      b.homeActive.value = true;
      expect(b.homeActive.value, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // cb7 — nullable callback slots default to null
  // ---------------------------------------------------------------------------
  group('cb7 nullable callback slots', () {
    test('cb7 all optional slots default to null', () {
      final b = ChromeBridge();
      expect(b.toggleLeftPanel, isNull);
      expect(b.setLeftPanelVisible, isNull);
      expect(b.openSettings, isNull);
      expect(b.openHistory, isNull);
      expect(b.openOnboarding, isNull);
      expect(b.openAgents, isNull);
      expect(b.openSeed, isNull);
      expect(b.selectTab, isNull);
      expect(b.closeTab, isNull);
      expect(b.listTabs, isNull);
      expect(b.openPackagePicker, isNull);
      expect(b.createNewPackage, isNull);
      expect(b.newProjectDialog, isNull);
      expect(b.openProjectDialog, isNull);
      expect(b.newProjectInActive, isNull);
      expect(b.openProjectInActive, isNull);
      expect(b.closeProjectInActive, isNull);
      expect(b.setActiveTabProject, isNull);
      expect(b.setCenterMode, isNull);
      expect(b.recordRecentProject, isNull);
    });

    test('cb7 slots can be assigned and retrieved', () {
      final b = ChromeBridge();
      b.toggleLeftPanel = () => true;
      expect(b.toggleLeftPanel!(), isTrue);

      b.selectTab = (i) => i;
      expect(b.selectTab!(3), 3);
    });
  });
}
