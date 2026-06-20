/// Unit tests for `AgentHost` synchronous lookup methods — the per-agent
/// tool projection, profile lookup by id, and the id resolver (legacy alias
/// map). `toolsFor` delegates to `KernelApp.toolsForAgent`, which projects the
/// kernel's registered endpoint tools through the profile's `toolNames` as an
/// explicit allowlist (glob-matched), so the tool-filtering test registers a
/// small catalog on the booted `KernelApp` rather than feeding it through the
/// (now host-side, not consulted by `toolsFor`) `fetchAllToolDefinitions`.
library;

import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' as fb;
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/agent/agent_host.dart';
import 'package:appplayer_studio/src/base/agent/agent_profile.dart';

void main() {
  late Directory tmpDir;
  late fb.KernelApp app;

  setUpAll(() async {
    tmpDir = Directory.systemTemp.createTempSync('agent_host_test_');
    app = await fb.KernelApp.boot(
      workspaceId: 'agent_host_test',
      kvStorage: fb.KvStoragePortAdapter(rootDir: tmpDir.path),
      bundleRegistryStorageDir: tmpDir.path,
    );
  });

  tearDownAll(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {
      /* best-effort */
    }
  });

  AgentHost _hostWith(
    List<VibeAgentProfile> profiles, {
    String Function(String)? resolveId,
    List<Map<String, dynamic>> Function()? fetchAllToolDefinitions,
  }) {
    return AgentHost(
      flowbrain: app,
      workspaceId: 'agent_host_test',
      fetchAllToolDefinitions:
          fetchAllToolDefinitions ?? () => const <Map<String, dynamic>>[],
      profiles: profiles,
      resolveId: resolveId,
    );
  }

  group('toolsFor', () {
    test('filters the kernel catalog by the profile.toolNames whitelist', () {
      // `toolsFor` → `KernelApp.toolsForAgent(explicitAllowlist: toolNames)`,
      // which glob-filters the kernel's registered endpoint tools. Register a
      // small catalog on the booted app, then verify the whitelist subset.
      const names = <String>[
        'studio.chrome.list_tabs',
        'studio.bundle.list',
        'studio.renderer.screenshot',
      ];
      final ep = app.addEndpoint(label: 'agent_host_toolsfor_test');
      for (final n in names) {
        ep.addTool(
          name: n,
          description: n,
          inputSchema: const <String, dynamic>{'type': 'object'},
          handler:
              (args) async =>
                  fb.KernelToolResult(content: const <fb.KernelContent>[]),
        );
      }
      addTearDown(() {
        for (final n in names) {
          ep.removeTool(n);
        }
      });
      final host = _hostWith(<VibeAgentProfile>[
        VibeAgentProfile(
          id: 'builder.manager',
          displayName: 'Builder Manager',
          role: fb.AgentRole.manager,
          modelId: 'claude-opus-4-7',
          systemPrompt: '',
          toolNames: const <String>[
            'studio.chrome.list_tabs',
            'studio.bundle.list',
          ],
        ),
      ]);
      final tools = host.toolsFor('builder.manager');
      expect(tools, hasLength(2));
      expect(tools.map((t) => t.name).toSet(), <String>{
        'studio.chrome.list_tabs',
        'studio.bundle.list',
      });
    });

    test('returns an empty list when the profile carries no toolNames', () {
      final host = _hostWith(
        <VibeAgentProfile>[
          VibeAgentProfile(
            id: 'silent.manager',
            displayName: 'Silent',
            role: fb.AgentRole.manager,
            modelId: 'claude-opus-4-7',
            systemPrompt: '',
            toolNames: const <String>[],
          ),
        ],
        fetchAllToolDefinitions:
            () => const <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'studio.chrome.list_tabs',
                'description': '',
                'parameters': <String, dynamic>{},
              },
            ],
      );
      expect(host.toolsFor('silent.manager'), isEmpty);
    });

    test('throws when the agent id is not registered', () {
      final host = _hostWith(const <VibeAgentProfile>[]);
      expect(() => host.toolsFor('ghost.agent'), throwsStateError);
    });
  });

  group('profileFor / resolveId', () {
    test('profileFor returns the registered profile when id matches', () {
      final p = VibeAgentProfile(
        id: 'studio.manager',
        displayName: 'Studio',
        role: fb.AgentRole.manager,
        modelId: 'claude-opus-4-7',
        systemPrompt: '',
        toolNames: const <String>[],
      );
      final host = _hostWith(<VibeAgentProfile>[p]);
      expect(host.profileFor('studio.manager'), same(p));
    });

    test('profileFor returns null when id is unknown', () {
      final host = _hostWith(const <VibeAgentProfile>[]);
      expect(host.profileFor('nope'), isNull);
    });

    test('resolveId honours the alias map supplied at construction', () {
      final aliasMap = <String, String>{'legacy.builder': 'builder.manager'};
      final host = _hostWith(<VibeAgentProfile>[
        VibeAgentProfile(
          id: 'builder.manager',
          displayName: 'Builder',
          role: fb.AgentRole.manager,
          modelId: 'claude-opus-4-7',
          systemPrompt: '',
          toolNames: const <String>[],
        ),
      ], resolveId: (raw) => aliasMap[raw] ?? raw);
      expect(host.resolveId('legacy.builder'), 'builder.manager');
      // profileFor goes through resolveId, so the alias hits the catalog.
      expect(host.profileFor('legacy.builder')?.id, 'builder.manager');
      // Unmapped ids pass through untouched.
      expect(host.resolveId('builder.manager'), 'builder.manager');
    });
  });
}
