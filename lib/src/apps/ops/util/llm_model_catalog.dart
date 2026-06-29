/// Catalog of LLM providers + their concrete model ids.
///
/// Single source for the Settings page Provider/Model dropdowns and the
/// member-form Provider/Model dropdowns. Keep entries aligned with the
/// providers the host `composeLlm` service actually instantiates — adding a
/// new option here without wiring the matching `LlmProvider` case in the host
/// `base/install/llm_capability.dart` `composeLlm` switch will throw at boot.
///
/// `id` is the verbatim provider key persisted in `OpsConfig.llm.providers`
/// and the `ModelSpec.provider` value passed to flowbrain. `models` is the
/// dropdown list — the `id` values are forwarded verbatim to the `mcp_llm`
/// provider, so they must match what the SDK accepts.
library;

class LlmModelOption {
  const LlmModelOption({required this.id, required this.label, this.note});

  /// Provider model id forwarded to mcp_llm verbatim (e.g. `claude-opus-4-7`).
  final String id;

  /// Short label for the dropdown row (e.g. `Opus 4.7`).
  final String label;

  /// Optional one-line cost / speed posture shown beneath the label.
  final String? note;
}

class LlmProviderOption {
  const LlmProviderOption({
    required this.id,
    required this.label,
    required this.models,
  });

  /// Provider key — `claude` / `openai` / `stub`. Matches both the config
  /// `llm.providers` map key and `ModelSpec.provider`.
  final String id;

  /// Human label rendered in the Provider dropdown.
  final String label;

  /// Available models. Order = preference (first = default for this provider).
  final List<LlmModelOption> models;

  LlmModelOption get defaultModel => models.first;
}

/// Production providers offered in the dropdowns. `stub` is intentionally
/// excluded — it is an internal fallback handled by the adapter when no
/// provider is configured, not a user-selectable option.
const List<LlmProviderOption> kLlmProviderCatalog = <LlmProviderOption>[
  LlmProviderOption(
    id: 'claude',
    label: 'Claude (Anthropic)',
    models: <LlmModelOption>[
      LlmModelOption(
        id: 'claude-opus-4-8',
        label: 'Opus 4.8',
        note: 'most capable · default',
      ),
      LlmModelOption(
        id: 'claude-opus-4-7',
        label: 'Opus 4.7',
        note: 'previous flagship',
      ),
      LlmModelOption(
        id: 'claude-sonnet-4-6',
        label: 'Sonnet 4.6',
        note: 'balanced · everyday',
      ),
      LlmModelOption(
        id: 'claude-haiku-4-5-20251001',
        label: 'Haiku 4.5',
        note: 'fast · light tasks',
      ),
    ],
  ),
  LlmProviderOption(
    id: 'openai',
    label: 'OpenAI',
    models: <LlmModelOption>[
      LlmModelOption(id: 'gpt-5.5', label: 'GPT-5.5', note: 'flagship'),
      LlmModelOption(
        id: 'gpt-5.4-mini',
        label: 'GPT-5.4 mini',
        note: 'fast · cheap',
      ),
    ],
  ),
  LlmProviderOption(
    id: 'gemini',
    label: 'Gemini (Google)',
    models: <LlmModelOption>[
      LlmModelOption(
        id: 'gemini-3.1-pro-preview',
        label: 'Gemini 3.1 Pro',
        note: 'flagship · reasoning',
      ),
      LlmModelOption(
        id: 'gemini-3.5-flash',
        label: 'Gemini 3.5 Flash',
        note: 'fast · agentic',
      ),
    ],
  ),
];

/// Sentinel option appended to every model dropdown — flips the surrounding
/// form into a free-text input so callers can type an SDK-supported model id
/// not yet listed in the catalog.
const LlmModelOption kCustomModelOption = LlmModelOption(
  id: '__custom__',
  label: 'Custom…',
  note: 'type any provider-supported model id',
);

/// Stub provider option — not in the public dropdown. Returned by
/// [findProviderOption] for `stub/stub-1` so the AgentDetailView header can
/// label such agents without throwing.
const LlmProviderOption kStubProviderOption = LlmProviderOption(
  id: 'stub',
  label: 'Stub (no real LLM)',
  models: <LlmModelOption>[LlmModelOption(id: 'stub-1', label: 'Stub-1')],
);

/// Lookup the provider option by id. Returns null when [id] is empty;
/// returns [kStubProviderOption] for `stub`. Other unknown ids return null
/// so callers can branch (e.g. show "Custom" UI).
LlmProviderOption? findProviderOption(String id) {
  if (id.isEmpty) return null;
  if (id == 'stub') return kStubProviderOption;
  for (final p in kLlmProviderCatalog) {
    if (p.id == id) return p;
  }
  return null;
}

/// Lookup a (provider, model) pair. Returns null when either is unknown so
/// the caller can fall back to free-text rendering.
LlmModelOption? findModelOption(String providerId, String modelId) {
  final p = findProviderOption(providerId);
  if (p == null) return null;
  for (final m in p.models) {
    if (m.id == modelId) return m;
  }
  return null;
}
