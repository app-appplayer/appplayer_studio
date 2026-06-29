/// One entry in a host's LLM model catalog. The chat header model
/// chip + Settings dialog dropdowns render from a list of these.
/// Class name kept as `VibeModelOption` for backwards-compat; semantics
/// are domain-agnostic (any Anthropic / OpenAI / etc. model id works).
library;

class VibeModelOption {
  const VibeModelOption({
    required this.id,
    required this.label,
    this.note,
    this.provider,
  });

  /// Provider model id — must match the value the LLM client forwards
  /// verbatim (e.g. `claude-opus-4-7`).
  final String id;

  /// Short UX label (e.g. `Opus 4.7`).
  final String label;

  /// Optional one-line description (cost / speed posture).
  final String? note;

  /// Provider id (e.g. `anthropic`, `openai`, `gemini`). Settings
  /// dialog groups model dropdown by provider and stores one API key
  /// per provider; selecting a model uses the matching provider's key.
  /// Null = legacy single-key behavior.
  final String? provider;
}

/// Catalog of LLM models the Studio chat can drive. Update here when the
/// platform releases a new family — the chat-header chip and the Settings
/// dialog both render from this list. Order = preference (top = current
/// default; same order as the dropdown menu).
const List<VibeModelOption> kVibeModelCatalog = <VibeModelOption>[
  VibeModelOption(
    id: 'claude-opus-4-8',
    label: 'Opus 4.8',
    note: 'most capable · default',
  ),
  VibeModelOption(
    id: 'claude-opus-4-7',
    label: 'Opus 4.7',
    note: 'previous flagship',
  ),
  VibeModelOption(
    id: 'claude-sonnet-4-6',
    label: 'Sonnet 4.6',
    note: 'balanced · everyday',
  ),
  VibeModelOption(
    id: 'claude-haiku-4-5-20251001',
    label: 'Haiku 4.5',
    note: 'fast · light tasks',
  ),
];
