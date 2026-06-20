/// Provider/Model selection dropdowns used by both the Settings page and
/// the member-form dialog. Keeps the catalog interpretation in one place
/// so the two surfaces cannot drift in defaults / labels / Custom flow.
library;

import 'package:flutter/material.dart';

import '../util/llm_model_catalog.dart';

/// Composite Model dropdown — renders a provider-aware list of catalog
/// models plus a "Custom…" sentinel that flips the surrounding form into a
/// free-text input for unsupported model ids.
///
/// The widget is stateless: callers drive [modelId] and react to
/// [onChanged] in their own state. When [modelId] equals
/// [kCustomModelOption.id] the [customController] TextField is shown and
/// becomes the actual source of the model id at save time.
class LlmModelDropdown extends StatelessWidget {
  const LlmModelDropdown({
    super.key,
    required this.providerId,
    required this.modelId,
    required this.customController,
    required this.onChanged,
    this.label = 'Model',
  });

  final String providerId;
  final String modelId;
  final TextEditingController customController;
  final ValueChanged<String> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final provider = findProviderOption(providerId);
    final scheme = Theme.of(context).colorScheme;
    if (provider == null) {
      // Unknown provider — surface a free-text field so the user can still
      // edit, but flag the situation in the helper text.
      return TextField(
        controller: customController,
        decoration: InputDecoration(
          labelText: label,
          helperText:
              'Provider "$providerId" not in catalog — model id forwarded as-is.',
          helperStyle: TextStyle(color: scheme.error, fontSize: 11),
        ),
      );
    }
    final items = <DropdownMenuItem<String>>[
      for (final m in provider.models)
        DropdownMenuItem(value: m.id, child: _ModelItemRow(option: m)),
      const DropdownMenuItem(
        value: '__custom__',
        child: _ModelItemRow(option: kCustomModelOption),
      ),
    ];
    final effectiveValue =
        items.any((it) => it.value == modelId)
            ? modelId
            : provider.defaultModel.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: effectiveValue,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: items,
          onChanged: (v) {
            if (v == null) return;
            onChanged(v);
          },
        ),
        if (modelId == kCustomModelOption.id) ...[
          const SizedBox(height: 8),
          TextField(
            controller: customController,
            decoration: const InputDecoration(
              labelText: 'Custom model id',
              hintText: 'e.g. claude-opus-4-7-latest, gpt-4o-mini-2024-07-18',
            ),
          ),
        ],
      ],
    );
  }
}

class _ModelItemRow extends StatelessWidget {
  const _ModelItemRow({required this.option});
  final LlmModelOption option;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(option.label, overflow: TextOverflow.ellipsis)),
        if (option.note != null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              option.note!,
              style: TextStyle(fontSize: 11, color: scheme.outline),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}
