/// Unit tests for `registerDebugTools` — the `studio.debug.*` MCP
/// introspection tools. Locked contract: every handler degrades to a
/// benign "not wired" envelope when its [ChromeBridge] slot is unset
/// (never throws), and once wired forwards args verbatim and reports
/// exactly what the slot / registry / filesystem holds. Filesystem-
/// backed tools (`bundles`, `knowledge_index`, `settings`,
/// `overrides`, `workspace_snapshot`, `history.*`) are exercised
/// against a real temp directory + a real `BundleInstallSurface`
/// (same objects `studio_main.dart` wires), not mocks.
///
/// `studio.debug.servers` uses a real `DomainServerManager` (its
/// constructor is a plain Dart object, no widget tree needed).
/// `studio.debug.agents` only covers the `AgentHost.shared == null`
/// branch — a populated `AgentHost` needs a live LLM-provider kernel
/// boot, out of scope for this focused pass (see
/// `standard_manager_send_test.dart` for that harness).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Rect;

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';
import 'package:appplayer_studio/src/base/install/bundle_history.dart';

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
  late Directory tmpDir;
  late mk.KernelServerHost boot;
  late ChromeBridge bridge;
  late mk.KnowledgeBundleRegistry registry;
  late mk.KnowledgeQueryEngine knowledgeEngine;
  late BundleInstallSurface bundles;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('debug_tools_test_');
    boot = mk.InProcessKernelServerHost()..register();
    bridge = ChromeBridge();
    registry = mk.KnowledgeBundleRegistry(
      storageDir: p.join(tmpDir.path, 'kbr'),
    );
    knowledgeEngine = mk.KnowledgeQueryEngine(registry: registry);
    bundles = BundleInstallSurface(
      bundleRegistry: registry,
      knowledgeEngine: knowledgeEngine,
      installedCacheDir: p.join(tmpDir.path, 'installed'),
    );
    registerDebugTools(
      boot,
      bridge: bridge,
      bundles: bundles,
      toolId: 'test.studio',
      displayName: 'Test Studio',
      defaultPort: 8842,
    );
  });

  tearDown(() async {
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {
      /* best-effort cleanup */
    }
  });

  group('studio.debug.config', () {
    test('d1 unwired debugConfig — identity fields only', () async {
      final out = await _call(boot, 'studio.debug.config');
      expect(out['toolId'], 'test.studio');
      expect(out['displayName'], 'Test Studio');
      expect(out['defaultPort'], 8842);
      expect(out['settingsFile'], VibeSettings.defaultPath('test.studio'));
    });

    test('d2 wired debugConfig merges + can override identity fields', () async {
      bridge.debugConfig = () => <String, dynamic>{
            'configRoot': tmpDir.path,
            'transport': 'stdio',
          };
      final out = await _call(boot, 'studio.debug.config');
      expect(out['configRoot'], tmpDir.path);
      expect(out['transport'], 'stdio');
      expect(out['toolId'], 'test.studio'); // still present
    });
  });

  group('studio.debug.tabs', () {
    test('d3 unwired debugTabs returns empty list', () async {
      final out = await _call(boot, 'studio.debug.tabs');
      expect(out['tabs'], isEmpty);
    });

    test('d4 wired debugTabs forwarded verbatim', () async {
      bridge.debugTabs = () => <Map<String, dynamic>>[
            {'index': 0, 'key': 'home', 'isHome': true},
          ];
      final out = await _call(boot, 'studio.debug.tabs');
      expect((out['tabs'] as List), hasLength(1));
      expect((out['tabs'] as List).first['key'], 'home');
    });
  });

  group('studio.debug.chrome', () {
    test('d5 default snapshot — every slot unwired, notifier defaults', () async {
      final out = await _call(boot, 'studio.debug.chrome');
      final wired = out['wired'] as Map<String, dynamic>;
      expect(wired['toggleLeftPanel'], isFalse);
      expect(wired['debugConfig'], isFalse);
      final notifiers = out['notifiers'] as Map<String, dynamic>;
      expect(notifiers['tabBarVisible'], isTrue);
      expect(notifiers['hasTabStrip'], isFalse);
      expect(notifiers['tabBarPeek'], isFalse);
    });

    test('d6 wiring a slot flips its wired flag only', () async {
      bridge.toggleLeftPanel = () => true;
      bridge.debugConfig = () => const <String, dynamic>{};
      final out = await _call(boot, 'studio.debug.chrome');
      final wired = out['wired'] as Map<String, dynamic>;
      expect(wired['toggleLeftPanel'], isTrue);
      expect(wired['debugConfig'], isTrue);
      expect(wired['selectTab'], isFalse);
    });
  });

  group('studio.debug.bundles', () {
    test('d7 empty registry returns empty list', () async {
      final out = await _call(boot, 'studio.debug.bundles');
      expect(out['bundles'], isEmpty);
    });

    test('d8 installed bundle dump includes resolved manifest', () async {
      final mbdDir = Directory(p.join(tmpDir.path, 'demo.mbd'))
        ..createSync(recursive: true);
      File(p.join(mbdDir.path, 'manifest.json')).writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'manifest': <String, dynamic>{'id': 'com.example.demo', 'name': 'Demo'},
        }),
      );
      final installed = await bundles.install(mbdDir.path);
      expect(installed['ok'], isTrue, reason: installed['error']?.toString() ?? '');

      final out = await _call(boot, 'studio.debug.bundles');
      final list = out['bundles'] as List;
      expect(list, hasLength(1));
      final entry = list.single as Map<String, dynamic>;
      expect(entry['mbdPath'], mbdDir.path);
      final manifest = entry['manifest'] as Map<String, dynamic>;
      expect((manifest['manifest'] as Map)['id'], 'com.example.demo');
    });
  });

  group('studio.debug.runtime_state', () {
    test('d9 unwired readActiveRuntimeState — empty state + reason', () async {
      final out = await _call(boot, 'studio.debug.runtime_state');
      expect(out['state'], isEmpty);
      expect(out['reason'], 'readActiveRuntimeState-not-wired');
    });

    test('d10 wired slot returns state + its keys', () async {
      bridge.readActiveRuntimeState = () => <String, Object?>{'count': 3};
      final out = await _call(boot, 'studio.debug.runtime_state');
      expect((out['state'] as Map)['count'], 3);
      expect(out['keys'], <String>['count']);
    });
  });

  group('studio.debug.set_state', () {
    test('d11 missing state arg rejected', () async {
      final r = await _callRaw(boot, 'studio.debug.set_state');
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['ok'], isFalse);
      expect(out['reason'], 'state (object) required');
    });

    test('d12 unwired updateRuntimeState rejected', () async {
      final r = await _callRaw(
        boot,
        'studio.debug.set_state',
        {'state': {'x': 1}},
      );
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['reason'], 'updateRuntimeState-not-wired');
    });

    test('d13 wired slot receives the state map, echoes keysWritten', () async {
      Map<String, dynamic>? captured;
      bridge.updateRuntimeState = (s) => captured = s;
      final out = await _call(
        boot,
        'studio.debug.set_state',
        {'state': {'a': 1, 'b': 'two'}},
      );
      expect(out['ok'], isTrue);
      expect((out['keysWritten'] as List)..sort(), <String>['a', 'b']);
      expect(captured, <String, dynamic>{'a': 1, 'b': 'two'});
    });
  });

  group('studio.debug.dispatch_tool', () {
    test('d14 missing tool arg rejected', () async {
      final r = await _callRaw(boot, 'studio.debug.dispatch_tool');
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['reason'], 'tool (string) required');
    });

    test('d15 unwired dispatchActiveRuntimeTool rejected', () async {
      final r = await _callRaw(
        boot,
        'studio.debug.dispatch_tool',
        {'tool': 'studio.scenario.read'},
      );
      expect(r.isError, isTrue);
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['reason'], 'dispatchActiveRuntimeTool-not-wired');
    });

    test('d16 wired slot forwards tool + params, wraps the response', () async {
      String? capturedTool;
      Map<String, dynamic>? capturedParams;
      bridge.dispatchActiveRuntimeTool = (tool, params) async {
        capturedTool = tool;
        capturedParams = params;
        return <String, dynamic>{'echo': params['x']};
      };
      final out = await _call(
        boot,
        'studio.debug.dispatch_tool',
        {'tool': 'studio.scenario.read', 'params': {'x': 7}},
      );
      expect(out['ok'], isTrue);
      expect(out['tool'], 'studio.scenario.read');
      expect((out['response'] as Map)['echo'], 7);
      expect(capturedTool, 'studio.scenario.read');
      expect(capturedParams, <String, dynamic>{'x': 7});
    });
  });

  group('studio.debug.dispatch_log', () {
    test('d17 ring buffer reflects prior dispatches; filters + limit apply', () async {
      // Prior calls (already logged by InProcessKernelServerHost.callTool).
      await boot.callTool('studio.debug.config', const {});
      await boot.callTool('studio.debug.tabs', const {});
      await boot.callTool('studio.debug.tabs', const {});

      final all = await _call(boot, 'studio.debug.dispatch_log');
      expect(all['count'], greaterThanOrEqualTo(3));

      final filtered = await _call(
        boot,
        'studio.debug.dispatch_log',
        {'tool': 'tabs'},
      );
      expect(filtered['count'], 2);
      for (final e in (filtered['entries'] as List)) {
        expect((e as Map)['tool'], 'studio.debug.tabs');
      }

      final limited = await _call(
        boot,
        'studio.debug.dispatch_log',
        {'limit': 1},
      );
      expect((limited['entries'] as List), hasLength(1));
    });

    test('d18 errorsOnly filter keeps only isError entries', () async {
      await boot.callTool('studio.debug.set_state', const {}); // errors (no state)
      await boot.callTool('studio.debug.tabs', const {}); // ok
      final out = await _call(
        boot,
        'studio.debug.dispatch_log',
        {'errorsOnly': true},
      );
      final entries = out['entries'] as List;
      expect(entries, isNotEmpty);
      for (final e in entries) {
        expect((e as Map)['isError'], isTrue);
      }
    });
  });

  group('studio.debug.screenshot', () {
    test('d19 unwired captureScreenshot — non-error not-wired envelope', () async {
      final r = await _callRaw(boot, 'studio.debug.screenshot');
      expect(r.isError, isNot(true));
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['ok'], isFalse);
      expect(out['reason'], 'captureScreenshot-not-wired');
    });

    test('d20 wired but capture root not attached (null bytes)', () async {
      bridge.captureScreenshot = ({Rect? area, double pixelRatio = 1.0}) async => null;
      final r = await _callRaw(boot, 'studio.debug.screenshot');
      final out = jsonDecode((r.content.first as mk.KernelTextContent).text)
          as Map<String, dynamic>;
      expect(out['ok'], isFalse);
      expect(out['reason'], 'capture root not attached');
    });

    test('d21 wired capture returns a base64 PNG image content', () async {
      double? capturedRatio;
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      bridge.captureScreenshot = ({Rect? area, double pixelRatio = 1.0}) async {
        capturedRatio = pixelRatio;
        return bytes;
      };
      final r = await _callRaw(boot, 'studio.debug.screenshot', {'pixelRatio': 2.0});
      final img = r.content.first as mk.KernelImageContent;
      expect(img.mimeType, 'image/png');
      expect(img.data, base64Encode(bytes));
      expect(capturedRatio, 2.0);
    });
  });

  group('studio.debug.layout_snapshot', () {
    test('d22 unwired captureLayoutSnapshot — empty nodes + reason', () async {
      final out = await _call(boot, 'studio.debug.layout_snapshot');
      expect(out['nodes'], isEmpty);
      expect(out['reason'], 'shell not mounted yet');
    });

    test('d23 wired but capture root not attached (null snapshot)', () async {
      bridge.captureLayoutSnapshot = () async => null;
      final out = await _call(boot, 'studio.debug.layout_snapshot');
      expect(out['nodes'], isEmpty);
      expect(out['reason'], 'capture root not attached');
    });

    test('d24 wired snapshot forwarded with the current view target', () async {
      bridge.captureLayoutSnapshot = () async => <Map<String, dynamic>>[
            {'type': 'Text', 'depth': 1},
          ];
      bridge.currentViewTarget = () => <String, dynamic>{'target': 'ui://app'};
      final out = await _call(boot, 'studio.debug.layout_snapshot');
      expect(out['view'], 'ui://app');
      expect((out['nodes'] as List), hasLength(1));
      expect(out.containsKey('reason'), isFalse);
    });
  });

  group('studio.debug.notify_log', () {
    test('d25 default empty log', () async {
      final out = await _call(boot, 'studio.debug.notify_log');
      expect(out['count'], 0);
      expect(out['entries'], isEmpty);
    });

    test('d26 records notify() calls; severity filter narrows them', () async {
      bridge.notify = (message, {severity}) {}; // wires the sink
      bridge.notify!('all good', severity: 'success');
      bridge.notify!('careful', severity: 'warning');
      bridge.notify!('boom', severity: 'error');

      final all = await _call(boot, 'studio.debug.notify_log');
      expect(all['count'], 3);

      final errorsOnly = await _call(
        boot,
        'studio.debug.notify_log',
        {'severity': 'error'},
      );
      expect(errorsOnly['count'], 1);
      expect((errorsOnly['entries'] as List).single['message'], 'boom');
    });
  });

  group('studio.debug.activation / activation_hub', () {
    test('d27 unwired debugActivation — not-wired envelope', () async {
      final out = await _call(boot, 'studio.debug.activation');
      expect(out['ok'], isFalse);
      expect(out['reason'], 'debugActivation-not-wired');
    });

    test('d28 wired debugActivation forwarded verbatim', () async {
      bridge.debugActivation = () => <String, dynamic>{
            'bundleShortId': 'demo',
            'tools': <String>['demo.shout'],
          };
      final out = await _call(boot, 'studio.debug.activation');
      expect(out['bundleShortId'], 'demo');
      expect(out['tools'], <String>['demo.shout']);
    });

    test('d29 activation_hub structurally valid (process-singleton registry)', () async {
      final out = await _call(boot, 'studio.debug.activation_hub');
      final list = out['bundles'] as List;
      expect(out['count'], list.length);
      for (final e in list) {
        expect(e, isA<Map>());
        expect((e as Map).containsKey('bundleId'), isTrue);
      }
    });
  });

  group('studio.debug.runtimes', () {
    test('d30 unwired debugRuntimes — empty tabs + reason', () async {
      final out = await _call(boot, 'studio.debug.runtimes');
      expect(out['tabs'], isEmpty);
      expect(out['reason'], 'debugRuntimes-not-wired');
    });

    test('d31 wired debugRuntimes forwarded verbatim', () async {
      bridge.debugRuntimes = () => <Map<String, dynamic>>[
            {'index': 1, 'tabKey': '/a.mbd'},
          ];
      final out = await _call(boot, 'studio.debug.runtimes');
      expect((out['tabs'] as List), hasLength(1));
    });
  });

  group('studio.debug.chat', () {
    test('d32 unwired debugChat — not-wired envelope', () async {
      final out = await _call(boot, 'studio.debug.chat');
      expect(out['ok'], isFalse);
      expect(out['reason'], 'debugChat-not-wired');
    });

    test('d33 wired debugChat receives the requested limit', () async {
      int? capturedLimit;
      bridge.debugChat = (limit) {
        capturedLimit = limit;
        return <String, dynamic>{'agentId': 'studio.manager', 'turnCount': 0};
      };
      final defaultOut = await _call(boot, 'studio.debug.chat');
      expect(capturedLimit, 20);
      expect(defaultOut['agentId'], 'studio.manager');

      await _call(boot, 'studio.debug.chat', {'limit': 5});
      expect(capturedLimit, 5);
    });
  });

  group('studio.debug.agents', () {
    test('d34 AgentHost.shared uninitialised — empty + reason', () async {
      final out = await _call(boot, 'studio.debug.agents');
      expect(out['count'], 0);
      expect(out['agents'], isEmpty);
      expect(out['reason'], 'AgentHost.shared not initialised');
    });
  });

  group('studio.debug.settings', () {
    test('d35 unwired debugConfig — no path, not exists', () async {
      final out = await _call(boot, 'studio.debug.settings');
      expect(out['path'], isNull);
      expect(out['exists'], isFalse);
    });

    test('d36 configRoot with a real settings.json is read back', () async {
      bridge.debugConfig = () => <String, dynamic>{'configRoot': tmpDir.path};
      File(p.join(tmpDir.path, 'settings.json')).writeAsStringSync(
        jsonEncode(<String, dynamic>{'workspaceDir': '/tmp/ws'}),
      );
      final out = await _call(boot, 'studio.debug.settings');
      expect(out['exists'], isTrue);
      expect((out['settings'] as Map)['workspaceDir'], '/tmp/ws');
    });
  });

  group('studio.debug.overrides', () {
    test('d37 no configRoot — actionable error', () async {
      final out = await _call(boot, 'studio.debug.overrides');
      expect(out['configRoot'], isNull);
      expect(out['error'], 'configRoot not configured');
    });

    test('d38 explicit path with no override file — exists:false entry', () async {
      bridge.debugConfig = () => <String, dynamic>{'configRoot': tmpDir.path};
      final out = await _call(
        boot,
        'studio.debug.overrides',
        {'path': '/Users/x/workspaces/app_builder'},
      );
      final files = out['files'] as List;
      expect(files, hasLength(1));
      final entry = files.single as Map;
      expect(entry['domain'], '/Users/x/workspaces/app_builder');
      expect(entry['exists'], isFalse);
    });

    test('d39 no path arg dumps every override file in the dir', () async {
      bridge.debugConfig = () => <String, dynamic>{'configRoot': tmpDir.path};
      final dir = Directory(p.join(tmpDir.path, 'package_settings'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'a.json'))
          .writeAsStringSync(jsonEncode({'inheritFromSystem': true}));
      File(p.join(dir.path, 'b.json'))
          .writeAsStringSync(jsonEncode({'inheritFromSystem': false}));
      final out = await _call(boot, 'studio.debug.overrides');
      final files = out['files'] as List;
      expect(files, hasLength(2));
      for (final f in files) {
        expect((f as Map)['exists'], isTrue);
        expect((f['content'] as Map).containsKey('inheritFromSystem'), isTrue);
      }
    });
  });

  group('studio.debug.workspace_snapshot', () {
    test('d40 no root resolvable — actionable error', () async {
      final out = await _call(boot, 'studio.debug.workspace_snapshot');
      expect(out['root'], isNull);
      expect(out['error'], 'workspaceDir not configured');
    });

    test('d41 explicit root that does not exist', () async {
      final out = await _call(
        boot,
        'studio.debug.workspace_snapshot',
        {'root': p.join(tmpDir.path, 'nope')},
      );
      expect(out['exists'], isFalse);
    });

    test('d42 classifies mbd / project / other entries under the root', () async {
      final root = Directory(p.join(tmpDir.path, 'ws'))..createSync();
      final mbd = Directory(p.join(root.path, 'pkg.mbd'))..createSync();
      File(p.join(mbd.path, 'manifest.json')).writeAsStringSync('{}');
      final proj = Directory(p.join(root.path, 'proj'))..createSync();
      File(p.join(proj.path, 'project.apbproj')).writeAsStringSync('{}');
      Directory(p.join(root.path, 'stray')).createSync();
      File(p.join(root.path, 'loose.txt')).writeAsStringSync('x');

      final out = await _call(
        boot,
        'studio.debug.workspace_snapshot',
        {'root': root.path},
      );
      expect(out['exists'], isTrue);
      expect((out['mbds'] as List), hasLength(1));
      expect((out['projects'] as List), hasLength(1));
      expect((out['other'] as List), containsAll(<String>['stray', 'loose.txt']));
      final counts = out['counts'] as Map;
      expect(counts['mbds'], 1);
      expect(counts['projects'], 1);
      expect(counts['other'], 2);
    });

    test('d43 falls back to settings.json workspaceDir when root omitted', () async {
      bridge.debugConfig = () => <String, dynamic>{'configRoot': tmpDir.path};
      final root = Directory(p.join(tmpDir.path, 'ws2'))..createSync();
      File(p.join(tmpDir.path, 'settings.json')).writeAsStringSync(
        jsonEncode(<String, dynamic>{'workspaceDir': root.path}),
      );
      final out = await _call(boot, 'studio.debug.workspace_snapshot');
      expect(out['root'], root.path);
      expect(out['exists'], isTrue);
    });
  });

  group('studio.debug.boot_log', () {
    test('d44 forwards recorded boot events, respects limit', () async {
      bridge.recordBootEvent('tabs.json restored');
      bridge.recordBootEvent('activated demo.mbd');
      final out = await _call(boot, 'studio.debug.boot_log');
      expect(out['count'], 2);
      final limited = await _call(boot, 'studio.debug.boot_log', {'limit': 1});
      expect((limited['entries'] as List), hasLength(1));
      expect((limited['entries'] as List).single['message'], 'activated demo.mbd');
    });
  });

  group('studio.debug.history.list / diff / restore', () {
    test('d45 missing mbdPath rejected on all three tools', () async {
      final listOut = await _call(boot, 'studio.debug.history.list');
      expect(listOut['ok'], isFalse);
      expect(listOut['error'], 'mbdPath required');

      final diffOut = await _call(boot, 'studio.debug.history.diff');
      expect(diffOut['ok'], isFalse);
      expect(diffOut['error'], 'mbdPath and id required');

      final restoreOut = await _call(boot, 'studio.debug.history.restore');
      expect(restoreOut['ok'], isFalse);
      expect(restoreOut['error'], 'mbdPath and id required');
    });

    test('d46 list with no history dir yet — zero entries', () async {
      final mbd = p.join(tmpDir.path, 'target.mbd');
      final out = await _call(
        boot,
        'studio.debug.history.list',
        {'mbdPath': mbd},
      );
      expect(out['count'], 0);
    });

    test('d47 diff / restore report snapshot-not-found before any snapshot exists', () async {
      final mbd = p.join(tmpDir.path, 'target.mbd');
      final diffOut = await _call(
        boot,
        'studio.debug.history.diff',
        {'mbdPath': mbd, 'id': '2026-01-01T00-00-00-label'},
      );
      expect(diffOut['ok'], isFalse);
      expect(diffOut['error'], 'snapshot not found');

      final restoreOut = await _call(
        boot,
        'studio.debug.history.restore',
        {'mbdPath': mbd, 'id': '2026-01-01T00-00-00-label'},
      );
      expect(restoreOut['ok'], isFalse);
      expect(restoreOut['error'], 'snapshot not found');
    });

    test(
      'd48 list finds a manually-seeded snapshot; diff reports before/after; '
      'restore copies snapshot content back onto the live file',
      () async {
        final mbdDir = Directory(p.join(tmpDir.path, 'target.mbd'))
          ..createSync(recursive: true);
        final liveFile = File(p.join(mbdDir.path, 'ui', 'app.json'))
          ..createSync(recursive: true);
        liveFile.writeAsStringSync('{"live":true}');

        final snapId = '2026-01-01T00-00-00-preEdit';
        final snapDir = Directory(
          p.join(bundleHistoryRootFor(mbdDir.path), snapId, 'ui'),
        )..createSync(recursive: true);
        File(p.join(snapDir.path, 'app.json'))
            .writeAsStringSync('{"live":false}');

        final listOut = await _call(
          boot,
          'studio.debug.history.list',
          {'mbdPath': mbdDir.path},
        );
        expect(listOut['count'], 1);
        final entry = (listOut['entries'] as List).single as Map;
        expect(entry['id'], snapId);
        expect(entry['label'], 'preEdit');
        expect((entry['files'] as List), contains(p.join('ui', 'app.json')));

        final diffOut = await _call(
          boot,
          'studio.debug.history.diff',
          {'mbdPath': mbdDir.path, 'id': snapId},
        );
        expect(diffOut['ok'], isTrue);
        final fileDiff = (diffOut['files'] as List).single as Map;
        expect(fileDiff['before'], '{"live":false}');
        expect(fileDiff['after'], '{"live":true}');
        expect(fileDiff['identical'], isFalse);

        var reloaded = false;
        bridge.reloadTab = (_) => reloaded = true;
        var marked = false;
        bridge.markActiveTabModified = () => marked = true;

        final restoreOut = await _call(
          boot,
          'studio.debug.history.restore',
          {'mbdPath': mbdDir.path, 'id': snapId},
        );
        expect(restoreOut['ok'], isTrue);
        expect(restoreOut['restored'], contains(p.join('ui', 'app.json')));
        expect(liveFile.readAsStringSync(), '{"live":false}');
        expect(reloaded, isTrue);
        expect(marked, isTrue);

        // A preRestore snapshot was captured so the restore is undoable.
        final preRestoreId = restoreOut['preRestoreSnapshot'] as String;
        final preRestoreDir = Directory(
          p.join(bundleHistoryRootFor(mbdDir.path), preRestoreId),
        );
        expect(preRestoreDir.existsSync(), isTrue);
      },
    );
  });

  group('studio.debug.header_actions', () {
    test('d49 default empty', () async {
      final out = await _call(boot, 'studio.debug.header_actions');
      expect(out['count'], 0);
      expect(out['actions'], isEmpty);
    });

    test('d50 maps tooltip/emphasised/divider off the live notifier', () async {
      bridge.headerActions.value = <HeaderAction>[
        HeaderAction(
          tooltip: 'Build',
          icon: Icons.build,
          onTap: () {},
          emphasised: true,
        ),
        HeaderAction(
          tooltip: 'Export',
          icon: Icons.upload,
          onTap: () {},
          divider: true,
        ),
      ];
      final out = await _call(boot, 'studio.debug.header_actions');
      expect(out['count'], 2);
      final actions = (out['actions'] as List).cast<Map>();
      expect(actions[0]['tooltip'], 'Build');
      expect(actions[0]['emphasised'], isTrue);
      expect(actions[1]['tooltip'], 'Export');
      expect(actions[1]['divider'], isTrue);
    });
  });

  group('studio.debug.knowledge_index', () {
    test('d51 no installed bundles — zeroed summary, empty docs', () async {
      final out = await _call(boot, 'studio.debug.knowledge_index');
      final summary = out['summary'] as Map;
      expect(summary['namespaces'], 0);
      expect(summary['sources'], 0);
      expect(summary['docs'], 0);
      expect(out['docs'], isEmpty);
    });

    test('d52 flattens an installed bundle\'s knowledge sources into doc rows', () async {
      final mbdDir = Directory(p.join(tmpDir.path, 'kdemo.mbd'))
        ..createSync(recursive: true);
      File(p.join(mbdDir.path, 'README.md'))
          .writeAsStringSync('# Demo\nSome content here.');
      File(p.join(mbdDir.path, 'manifest.json')).writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'manifest': <String, dynamic>{'id': 'com.example.kdemo'},
          'knowledge': <String, dynamic>{
            'sources': <dynamic>[
              <String, dynamic>{
                'id': 'docs',
                'docs': <dynamic>[
                  <String, dynamic>{
                    'id': 'readme',
                    'path': 'README.md',
                    'title': 'Readme',
                  },
                  <String, dynamic>{
                    'id': 'inline',
                    'content': 'hello world inline content',
                  },
                ],
              },
            ],
          },
        }),
      );
      final installed = await bundles.install(mbdDir.path);
      expect(installed['ok'], isTrue, reason: installed['error']?.toString() ?? '');

      final out = await _call(boot, 'studio.debug.knowledge_index');
      final summary = out['summary'] as Map;
      expect(summary['namespaces'], 1);
      expect(summary['sources'], 1);
      expect(summary['docs'], 2);
      final docs = (out['docs'] as List).cast<Map>();
      final readme = docs.singleWhere((d) => d['docId'] == 'readme');
      expect(readme['namespace'], 'com.example.kdemo');
      expect(readme['sourceId'], 'docs');
      expect(readme['title'], 'Readme');
      expect(readme['sizeBytes'], greaterThan(0));
      final inline = docs.singleWhere((d) => d['docId'] == 'inline');
      expect(inline['sizeBytes'], 'hello world inline content'.length);

      // namespace filter narrows to the matching bundle only.
      final filtered = await _call(
        boot,
        'studio.debug.knowledge_index',
        {'namespace': 'com.example.kdemo'},
      );
      expect(((filtered['summary'] as Map)['docs']), 2);
      final noMatch = await _call(
        boot,
        'studio.debug.knowledge_index',
        {'namespace': 'nope'},
      );
      expect(((noMatch['summary'] as Map)['docs']), 0);

      // summary:true suppresses the docs array.
      final summaryOnly = await _call(
        boot,
        'studio.debug.knowledge_index',
        {'summary': true},
      );
      expect(summaryOnly.containsKey('docs'), isFalse);
    });
  });

  group('studio.debug.servers', () {
    test('d53 unwired domainServerManager — empty pool, no systemUrl key', () async {
      final out = await _call(boot, 'studio.debug.servers');
      expect(out['servers'], isEmpty);
      expect(out.containsKey('systemUrl'), isFalse);
    });

    test('d54 wired manager surfaces the system instance + its URL', () async {
      final systemBoot = mk.InProcessKernelServerHost()..register();
      bridge.domainServerManager = DomainServerManager.bootWithSystem(
        boot: systemBoot,
        url: 'http://127.0.0.1:8842',
        spawn: (url) async => mk.InProcessKernelServerHost(),
      );
      final out = await _call(boot, 'studio.debug.servers');
      expect(out['systemUrl'], 'http://127.0.0.1:8842');
      final servers = (out['servers'] as List).cast<Map>();
      expect(servers, hasLength(1));
      expect(servers.single['kind'], 'system');
      expect(servers.single['state'], 'active');
      expect(servers.single['url'], 'http://127.0.0.1:8842');
    });
  });
}
