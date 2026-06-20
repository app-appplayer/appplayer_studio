/// Per-agent profile data class — what model / system prompt / tool
/// surface to use when registering and invoking that agent.
///
/// Domain tools (vibe_app_builder, knowledge_builder, ...) supply a
/// catalog of these profiles to `AgentHost` at boot. Generic — naming
/// is kept as `VibeAgentProfile` for backwards-compat with existing
/// vibe code that imports the type by this name.
library;

import 'package:brain_kernel/brain_kernel.dart' as fb;

class VibeAgentProfile {
  const VibeAgentProfile({
    required this.id,
    required this.displayName,
    required this.modelId,
    required this.systemPrompt,
    required this.toolNames,
    required this.role,
    this.provider = 'anthropic',
  });

  final String id;
  final String displayName;

  /// Provider id — must match an entry in the host model catalog and an
  /// `LlmPortAdapter` registered in `KernelApp.agentLlmSessions`
  /// (`'anthropic'` / `'openai'` / `'gemini'` / `'claude_code'`). Default
  /// `'anthropic'` preserves legacy callers that pre-date this field.
  final String provider;

  /// Model id — must match a key in `KernelApp.agentLlmSessions`.
  final String modelId;

  /// Per-agent system prompt. FlowBrain stores this with the agent
  /// and prepends to every `ask` automatically.
  final String systemPrompt;

  /// Tool names this agent is allowed to call — the host filters the
  /// global tool catalog (provided via callback) by this list.
  final List<String> toolNames;

  final fb.AgentRole role;
}
