/// Smoke tests for the `StudioBackbone` → `KernelApp` wrapper landed
/// in the kernel-app porting track (Round B, 2026-05-24). Verify the
/// invariants the chrome cascade relies on:
///
///  1. `backbone.app` exposes the booted KernelApp.
///  2. `backbone.bundleRegistry` / `knowledgeEngine` getters forward
///     to the KernelApp's instances (same ref, not a fresh copy).
///  3. `backbone.isFlowBrainBooted` is `true` once the KernelApp is up
///     (KernelApp existence == booted per the porting contract).
///  4. `backbone.app.system` / `workspaceId` are reachable through the
///     wrapper without exposing the private `_wiring`.
library;

import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' as fb;
import 'package:brain_kernel/mcp_host.dart' show McpClientKernelHost;
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart' show StudioBackbone;

void main() {
  late Directory tmpDir;
  late fb.KernelApp app;
  late StudioBackbone backbone;

  setUpAll(() async {
    tmpDir = Directory.systemTemp.createTempSync('vibe_studio_backbone_');
    app = await fb.KernelApp.boot(
      workspaceId: 'vibe_studio_test',
      kvStorage: fb.KvStoragePortAdapter(rootDir: tmpDir.path),
      bundleRegistryStorageDir: tmpDir.path,
    );
    backbone = StudioBackbone(
      toolId: 'vibe_studio_test',
      configRoot: tmpDir.path,
      app: app,
      clientHost: McpClientKernelHost(),
      agentHost: null,
      growth: null,
      seedLoader: null,
    );
  });

  tearDownAll(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {
      /* best-effort cleanup */
    }
  });

  test('backbone.app exposes the booted KernelApp', () {
    expect(backbone.app, same(app));
    expect(backbone.app.system, isNotNull);
    expect(backbone.app.workspaceId, equals('vibe_studio_test'));
  });

  test('backbone.bundleRegistry forwards from KernelApp', () {
    expect(backbone.bundleRegistry, same(app.bundleRegistry));
  });

  test('backbone.knowledgeEngine forwards from KernelApp.queryEngine', () {
    expect(backbone.knowledgeEngine, same(app.queryEngine));
  });

  test('backbone.isFlowBrainBooted is true while the KernelApp exists', () {
    expect(backbone.isFlowBrainBooted, isTrue);
  });

  test('KernelApp.setActiveBundle mirrors back through backbone.app', () {
    expect(backbone.app.activeBundleId, isNull);
    backbone.app.setActiveBundle('app_builder');
    expect(backbone.app.activeBundleId, equals('app_builder'));
    expect(
      backbone.app.scopeIdFor('helloTool'),
      equals('app_builder.helloTool'),
    );
    backbone.app.setActiveBundle(null);
    expect(backbone.app.activeBundleId, isNull);
    expect(backbone.app.scopeIdFor('helloTool'), equals('helloTool'));
  });

  test('addEndpoint registers an endpoint into the shared pool', () {
    final ep = backbone.app.addEndpoint(label: 'unit_test', appName: 'unit');
    expect(ep, isNotNull);
    // Idempotent — second call returns the same instance.
    final ep2 = backbone.app.addEndpoint(label: 'unit_test', appName: 'unit');
    expect(ep2, same(ep));
    final labels = backbone.app.endpoints.map((e) => e.label).toSet();
    expect(labels, contains('unit_test'));
  });
}
