/// Host LLM **composition** service — owns provider construction so built-ins
/// don't.
///
/// A built-in must not build LLM providers itself (the `claude`/`openai`
/// `new` is business logic — `feedback_studio_rule_builtin_no_logic`). This
/// host service takes credential-bearing specs and returns the composed
/// flowbrain ports (`bundle.LlmPort` pool + default), which a built-in then
/// *consumes* when it wires the kernel (`InfraPorts.llmProviders` /
/// `KnowledgePorts.llm` / `AgentLlmSessions`). The kernel already accepts
/// these — no kernel change (cherry
/// `llm-provider-composition-answer-from-cherry-2026-06-14`).
///
/// Not a tool surface: provider composition is boot-time port construction,
/// not a runtime `callTool`. The seam is a direct host function the built-in
/// invokes at boot. Telemetry decoration (e.g. a recording port) stays with
/// the consumer — this service only constructs raw provider ports so it never
/// depends on a built-in's observability module.
library;

import 'package:appplayer_claude_code_provider/appplayer_claude_code_provider.dart'
    show ClaudeCodeInteractiveProvider, ProcessClaudeRunner;
import 'package:mcp_bundle/mcp_bundle.dart' as bundle;
import 'package:mcp_llm/mcp_llm.dart';

/// Host-neutral provider credential spec. The consumer maps its own settings
/// to these (provider [name] = `'claude'` | `'openai'`).
class LlmProviderSpec {
  const LlmProviderSpec({
    required this.name,
    required this.apiKey,
    required this.model,
  });

  final String name;
  final String apiKey;
  final String model;
}

/// Result of [composeLlm]: the per-name provider pool (for per-agent
/// `ModelSpec.provider` routing), the default port (for non-agent code), and
/// whether any internal provider is configured.
class LlmComposition {
  const LlmComposition({
    required this.providerPool,
    required this.defaultLlmPort,
    required this.hasInternalLlm,
  });

  /// `<providerName, LlmPort>` — every configured provider with a non-empty
  /// api key. Empty for external-MCP-only deployments.
  final Map<String, bundle.LlmPort> providerPool;

  /// Default port selected by `defaultProvider`; a [bundle.StubLlmPort] when
  /// no usable provider is configured.
  final bundle.LlmPort defaultLlmPort;

  /// True when a real default provider is wired (gates skill `llm` steps and
  /// the chat pane).
  final bool hasInternalLlm;
}

/// Compose flowbrain LLM ports from host-neutral provider [specs].
///
/// Builds every spec with a non-empty api key into the pool; the spec whose
/// [LlmProviderSpec.name] equals [defaultProvider] becomes the default port.
/// Unknown provider names paired with a non-empty key throw (genuine
/// misconfiguration); an empty [defaultProvider] or no usable provider yields
/// a stub default and `hasInternalLlm: false`.
LlmComposition composeLlm({
  required List<LlmProviderSpec> specs,
  required String defaultProvider,
  required int timeoutSeconds,
}) {
  final config = LlmConfiguration(timeout: Duration(seconds: timeoutSeconds));

  LlmProvider buildProvider(LlmProviderSpec spec) {
    switch (spec.name) {
      case 'claude':
        return ClaudeProvider(
          apiKey: spec.apiKey,
          model: spec.model,
          config: config,
        );
      case 'openai':
        return OpenAiProvider(
          apiKey: spec.apiKey,
          model: spec.model,
          config: config,
        );
      case 'claude_code':
        // Subscription path (no API key) — the same provider studio_boot
        // wires for the agent stack, surfaced here so ops' `hasInternalLlm`
        // recognizes claude_code as a real provider instead of reporting
        // "no LLM provider" while chat actually responds through it.
        return ClaudeCodeInteractiveProvider(
          name: spec.model,
          runner: ProcessClaudeRunner(executable: 'claude'),
        );
      default:
        throw StateError('Unsupported LLM provider: ${spec.name}');
    }
  }

  final pool = <String, bundle.LlmPort>{};
  for (final spec in specs) {
    // claude_code needs no API key (subprocess); every other provider does.
    if (spec.apiKey.isEmpty && spec.name != 'claude_code') continue;
    pool[spec.name] = LlmPortAdapterFactory.full(buildProvider(spec));
  }

  bundle.LlmPort defaultPort = bundle.StubLlmPort();
  var hasInternal = false;
  if (defaultProvider.isNotEmpty) {
    for (final spec in specs) {
      if (spec.name != defaultProvider) continue;
      if (spec.apiKey.isEmpty && spec.name != 'claude_code') continue;
      defaultPort = LlmPortAdapterFactory.full(buildProvider(spec));
      hasInternal = true;
      break;
    }
  }

  return LlmComposition(
    providerPool: pool,
    defaultLlmPort: defaultPort,
    hasInternalLlm: hasInternal,
  );
}
