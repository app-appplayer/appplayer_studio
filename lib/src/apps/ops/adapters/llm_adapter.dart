// Port DTO types live in mcp_bundle (flowbrain shim does not re-export
// capability DTOs — direct import is the capability-DTO path).
import 'package:meta/meta.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as bundle;
import 'package:appplayer_studio/base.dart' show composeLlm, LlmProviderSpec;

import '../config/ops_config.dart';
import '../observability/observability_module.dart';
import '../observability/recording_llm_port.dart';

/// LLM holder — the host-composed flowbrain `LlmPort`s the built-in consumes
/// when it wires the kernel.
///
/// See `docs/03_DDD/builtin-llm-migration.md`. Provider construction lives in
/// the host `composeLlm` service (no `claude`/`openai` `new` in the built-in);
/// this holder only maps settings → host specs and layers the built-in's own
/// telemetry (`RecordingLlmPort`) on top.
///
/// Neither outbound nor inbound MCP lives here anymore:
///   - outbound → host `mcp.*` capability (kernel `clientHost`) (S-LLM-2);
///   - inbound serving → host `KernelServerHost`; skill/system tools register
///     on the host endpoint (`BuiltinToolRegistry`) and dispatch runs through
///     it (`SkillExecutor.callHostTool`) (S-LLM-3).
class LlmAdapter {
  LlmAdapter._({
    required this.llmPort,
    required this.providerPool,
    required this.hasInternalLlm,
  });

  final bundle.LlmPort llmPort;

  /// All wired LLM providers keyed by provider name (`'claude'`/`'openai'`/
  /// ...). `flowbrain.InfraPorts.llmProviders` consumes this map so each
  /// agent's `ModelSpec.provider` resolves to the right port. Empty when
  /// no internal LLM provider is configured.
  final Map<String, bundle.LlmPort> providerPool;

  /// True when a default internal provider is configured — gates Skill `llm`
  /// steps and the built-in chat pane.
  final bool hasInternalLlm;

  /// Test-only factory — a stub port, no providers.
  @visibleForTesting
  static LlmAdapter forTests() => LlmAdapter._(
    llmPort: bundle.StubLlmPort(),
    providerPool: const {},
    hasInternalLlm: false,
  );

  static Future<LlmAdapter> build({
    required LlmSettings llm,
    ObservabilityModule? observability,
  }) async {
    // Provider construction is host-owned (`composeLlm`, base/install/
    // llm_capability.dart) — the built-in maps its settings to host-neutral
    // specs and consumes the composed flowbrain ports. Agents target any
    // provider via `ModelSpec.provider`; non-agent code falls back to the
    // default port (selected by `LlmSettings.defaultProvider`). Telemetry
    // decoration (`RecordingLlmPort`) stays here — it's the built-in's own
    // observability concern, layered on top of the host-composed ports.
    final composition = composeLlm(
      specs: <LlmProviderSpec>[
        for (final e in llm.providers.entries)
          LlmProviderSpec(
            name: e.key,
            apiKey: e.value.apiKey,
            model: e.value.model,
          ),
      ],
      defaultProvider: llm.defaultProvider,
      timeoutSeconds: llm.timeoutSeconds,
    );
    final rawPool = composition.providerPool;
    final pool =
        observability == null
            ? rawPool
            : <String, bundle.LlmPort>{
              for (final e in rawPool.entries)
                e.key: RecordingLlmPort(
                  inner: e.value,
                  provider: e.key,
                  bus: observability.bus,
                  telemetry: observability.telemetry,
                ),
            };
    bundle.LlmPort llmPort = composition.defaultLlmPort;
    if (observability != null && composition.hasInternalLlm) {
      llmPort = RecordingLlmPort(
        inner: llmPort,
        provider: llm.defaultProvider,
        bus: observability.bus,
        telemetry: observability.telemetry,
      );
    }

    return LlmAdapter._(
      llmPort: llmPort,
      providerPool: pool,
      hasInternalLlm: composition.hasInternalLlm,
    );
  }

  Future<void> start() async {
    // Nothing to start — the holder owns no live managers.
  }

  Future<void> shutdown() async {
    // Nothing to dispose — outbound/inbound MCP live in the host now.
  }
}
