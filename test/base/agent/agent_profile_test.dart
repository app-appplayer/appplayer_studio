/// Unit coverage for `VibeAgentProfile` — construction, field access,
/// provider default, and role propagation. Pure Dart value-class tests,
/// no Flutter widget environment needed.
library;

import 'package:brain_kernel/brain_kernel.dart' show AgentRole;
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

VibeAgentProfile _minimal({
  String id = 'test.agent',
  String displayName = 'Test Agent',
  String modelId = 'claude-opus-4-7',
  String systemPrompt = 'You are a test agent.',
  List<String> toolNames = const <String>['studio.chrome.list_tabs'],
  AgentRole role = AgentRole.worker,
  String? provider,
}) {
  if (provider != null) {
    return VibeAgentProfile(
      id: id,
      displayName: displayName,
      modelId: modelId,
      systemPrompt: systemPrompt,
      toolNames: toolNames,
      role: role,
      provider: provider,
    );
  }
  return VibeAgentProfile(
    id: id,
    displayName: displayName,
    modelId: modelId,
    systemPrompt: systemPrompt,
    toolNames: toolNames,
    role: role,
  );
}

void main() {
  group('VibeAgentProfile construction', () {
    test('all required fields accessible', () {
      final p = _minimal();
      expect(p.id, 'test.agent');
      expect(p.displayName, 'Test Agent');
      expect(p.modelId, 'claude-opus-4-7');
      expect(p.systemPrompt, 'You are a test agent.');
      expect(p.toolNames, <String>['studio.chrome.list_tabs']);
      expect(p.role, AgentRole.worker);
    });

    test('provider defaults to anthropic when omitted', () {
      final p = _minimal();
      expect(p.provider, 'anthropic');
    });

    test('provider is stored verbatim when supplied', () {
      final p = _minimal(provider: 'openai');
      expect(p.provider, 'openai');
    });

    test('every AgentRole value can be stored', () {
      for (final role in AgentRole.values) {
        final p = _minimal(role: role);
        expect(p.role, role);
      }
    });

    test('empty toolNames list is stored intact', () {
      final p = _minimal(toolNames: const <String>[]);
      expect(p.toolNames, isEmpty);
    });

    test('multiple tool names preserved in order', () {
      const tools = <String>[
        'studio.chrome.list_tabs',
        'studio.bundle.list',
        'studio.renderer.screenshot',
      ];
      final p = _minimal(toolNames: tools);
      expect(p.toolNames, tools);
    });

    test('const construction compiles (compile-time constant check)', () {
      // Verify the class is const-constructible.
      const p = VibeAgentProfile(
        id: 'const.agent',
        displayName: 'Const',
        modelId: 'claude-haiku',
        systemPrompt: '',
        toolNames: <String>[],
        role: AgentRole.manager,
      );
      expect(p.id, 'const.agent');
      expect(p.provider, 'anthropic');
    });

    test('manager role profile has role == AgentRole.manager', () {
      final p = _minimal(role: AgentRole.manager);
      expect(p.role, AgentRole.manager);
      expect(p.role, isNot(AgentRole.worker));
    });

    test('different ids produce distinct instances', () {
      final a = _minimal(id: 'agent.a');
      final b = _minimal(id: 'agent.b');
      expect(a.id, isNot(b.id));
    });
  });
}
