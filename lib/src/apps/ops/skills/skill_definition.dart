/// Parsed representation of a Skill YAML definition.
///
/// See `SRS §2.10 FR-OPS-011` for the YAML schema.
class SkillDefinition {
  SkillDefinition({
    required this.id,
    required this.version,
    required this.description,
    this.inputSchema = const {},
    this.outputSchema = const {},
    required this.actionBody,
    this.budget,
    this.tags = const [],
  });

  final String id;
  final int version;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Map<String, dynamic> outputSchema;
  final ActionBody actionBody;
  final SkillBudget? budget;
  final List<String> tags;

  factory SkillDefinition.fromYaml(Map<String, dynamic> y) {
    final rawVersion = y['version'];
    final version =
        rawVersion is int
            ? rawVersion
            : rawVersion is num
            ? rawVersion.toInt()
            : rawVersion is String
            ? (int.tryParse(rawVersion) ?? 1)
            : 1;
    // Accept both `actionBody` (canonical) and `action` (shorthand commonly
    // typed by external LLMs / generated YAML).
    final body = y['actionBody'] ?? y['action'];
    return SkillDefinition(
      id: y['id'] as String,
      version: version,
      description: (y['description'] as String?) ?? '',
      inputSchema: _mapOrEmpty(y['inputSchema']),
      outputSchema: _mapOrEmpty(y['outputSchema']),
      actionBody: ActionBody.fromYaml(body),
      budget:
          y['budget'] is Map
              ? SkillBudget.fromYaml(_mapOrEmpty(y['budget']))
              : null,
      tags: (y['tags'] as List?)?.cast<String>() ?? const [],
    );
  }
}

class ActionBody {
  ActionBody({
    required this.kind,
    this.steps = const [],
    this.data = const {},
    this.inputs = const {},
  });

  /// llm | browser | mcp | fact.save | fact.query | ingest | form |
  /// channel | composite | map | scripted
  final String kind;
  final List<ActionStep> steps;
  final Map<String, dynamic> data;
  final Map<String, dynamic> inputs;

  factory ActionBody.fromYaml(Object? y) {
    if (y is! Map) return ActionBody(kind: 'noop');
    final m = Map<String, dynamic>.from(y);
    final kind = (m['kind'] as String?) ?? 'noop';
    final steps = <ActionStep>[];
    if (m['steps'] is List) {
      for (final s in m['steps'] as List) {
        if (s is Map) {
          steps.add(ActionStep.fromYaml(Map<String, dynamic>.from(s)));
        }
      }
    }
    final data =
        m['data'] is Map
            ? Map<String, dynamic>.from(m['data'] as Map)
            : <String, dynamic>{};
    final inputs =
        m['inputs'] is Map
            ? Map<String, dynamic>.from(m['inputs'] as Map)
            : <String, dynamic>{};
    return ActionBody(kind: kind, steps: steps, data: data, inputs: inputs);
  }
}

class ActionStep {
  ActionStep({
    required this.kind,
    this.id,
    this.output,
    this.inputs = const {},
    this.data = const {},
  });

  /// Same kinds as [ActionBody.kind] — `llm` / `browser` / `mcp` / etc.
  final String kind;
  final String? id;
  final String? output;
  final Map<String, dynamic> inputs;
  final Map<String, dynamic> data;

  factory ActionStep.fromYaml(Map<String, dynamic> m) {
    final kind = (m['kind'] as String?) ?? 'noop';
    final inputs = _mapOrEmpty(m['inputs']);
    // If the step has an explicit `data:` block, use it as-is. Otherwise
    // collect the remaining top-level keys (a shorthand form some YAMLs use,
    // e.g., `prompt:`/`temperature:` directly under an `llm` step).
    Map<String, dynamic> data;
    if (m['data'] is Map) {
      data = Map<String, dynamic>.from(m['data'] as Map);
    } else {
      data =
          Map<String, dynamic>.from(m)
            ..remove('kind')
            ..remove('id')
            ..remove('output')
            ..remove('inputs')
            ..remove('data');
    }
    return ActionStep(
      kind: kind,
      id: m['id'] as String?,
      output: m['output'] as String?,
      inputs: inputs,
      data: data,
    );
  }
}

class SkillBudget {
  SkillBudget({this.llmTokens, this.timeMs});
  final int? llmTokens;
  final int? timeMs;

  factory SkillBudget.fromYaml(Map<String, dynamic> m) => SkillBudget(
    llmTokens: m['llmTokens'] as int?,
    timeMs: m['timeMs'] as int?,
  );
}

Map<String, dynamic> _mapOrEmpty(Object? y) {
  if (y is Map) return Map<String, dynamic>.from(y);
  return <String, dynamic>{};
}
