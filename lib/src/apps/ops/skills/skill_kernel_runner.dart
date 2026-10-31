import 'package:mcp_bundle/mcp_bundle.dart' as bundle;
import 'package:mcp_knowledge/mcp_knowledge.dart' as ks;

import 'skill_definition.dart';

/// Name of the one tool the Ops step port answers. Every Ops step becomes one
/// kernel `tool` step that calls it; the kernel orders the steps, renders their
/// templates and hands results on, and the step itself is run by Ops.
const String kOpsStepTool = 'ops.step';

/// A skill the converter cannot express; the caller runs it on the Ops engine.
class SkillConversionRefused implements Exception {
  SkillConversionRefused(this.reason);
  final String reason;
  @override
  String toString() => 'SkillConversionRefused: $reason';
}

/// A skill converted for the kernel. [endsWithLlm]: the last step is an `llm`
/// step the kernel runs itself, whose answer is a plain string — the run puts
/// Ops' own answer shape (`{text, usage, model, source}`) back around it.
class OpsConversion {
  const OpsConversion(this.module, {required this.endsWithLlm});
  final bundle.SkillModule module;
  final bool endsWithLlm;
}

/// Turns a resolved Ops [SkillDefinition] into the kernel's skill module and
/// runs it.
///
/// The definition stays the source of truth (nothing about how a skill is
/// stored changes); the conversion happens at run time, per call, and carries
/// no state between calls.
class OpsSkillConverter {
  const OpsSkillConverter._();

  /// The conversion of [def], or throws [SkillConversionRefused].
  static OpsConversion convert(
    SkillDefinition def, {
    String? actorId,
    String? workspaceId,
  }) {
    final steps = <ActionStep>[];
    final body = def.actionBody;
    if (body.kind == 'composite') {
      steps.addAll(body.steps);
    } else {
      steps.add(
        ActionStep(kind: body.kind, data: body.data, inputs: body.inputs),
      );
    }
    final scope = _Scope(
      actorId: actorId ?? '',
      workspaceId: workspaceId ?? '',
    );
    final kernelSteps = <Map<String, dynamic>>[];
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final id = 's$i';
      final browserOp = _browserOperation(step);
      final llm = browserOp == null ? _nativeLlm(step, scope) : null;
      final factList = llm == null ? _nativeFactQuery(step, scope) : null;
      kernelSteps.add(<String, dynamic>{
        'id': id,
        'name': step.id ?? id,
        // `llm`: the kernel's own step, over the Ops completion rule.
        'action':
            llm ??
            factList ??
            (browserOp != null
                // The host's browser capability, called by the kernel itself.
                ? <String, dynamic>{
                  'type': 'tool',
                  'tool': 'browser.$browserOp',
                  'args': _value(step.inputs, scope),
                }
                : <String, dynamic>{
                  'type': 'tool',
                  'tool': kOpsStepTool,
                  'args': <String, dynamic>{
                    'kind': _literal(step.kind),
                    'inputs': _value(step.inputs, scope),
                    'data': _value(step.data, scope),
                  },
                }),
      });
      if (llm != null) scope.llmSteps.add(id);
      // Registered after the step's own templates were converted: a step
      // cannot read its own output, only an earlier one.
      final out = step.output;
      if (out != null) scope.outputs[out] = id;
    }
    if (kernelSteps.isNotEmpty) {
      kernelSteps.add(<String, dynamic>{
        'id': 'end',
        'name': 'end',
        'action': <String, dynamic>{
          'type': 'output',
          'value': '\${steps.s${steps.length - 1}.result}',
        },
      });
    }
    return OpsConversion(
      bundle.SkillModule.fromJson(<String, dynamic>{
        'id': def.id,
        'name': def.id,
        'version': '${def.version}.0.0',
        'description': def.description,
        'procedures': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'default',
            'name': 'default',
            'steps': kernelSteps,
          },
        ],
      }),
      endsWithLlm:
          kernelSteps.isNotEmpty &&
          scope.llmSteps.contains('s${steps.length - 1}'),
    );
  }

  /// An `llm` step the kernel can run with the same effect: the prompt is
  /// text, the numbers are plain numbers (the Ops step reads them with a type
  /// check that fails on anything else), and the model's answer is only ever
  /// read as `text`. The claim extraction the kernel would otherwise run on
  /// every answer — an extra model call — is switched off.
  static Map<String, dynamic>? _nativeLlm(ActionStep step, _Scope scope) {
    if (step.kind != 'llm') return null;
    final prompt = step.data['prompt'] ?? step.inputs['prompt'];
    final temperature = step.data['temperature'];
    final maxTokens = step.data['maxTokens'];
    final system = step.data['systemPrompt'];
    if (prompt != null && prompt is! String) return null;
    if (temperature != null && temperature is! num) return null;
    if (maxTokens != null && maxTokens is! int) return null;
    if (system != null && system is! String) return null;
    // The kernel hands the system prompt on as written — it renders templates
    // in the prompt only — so one that holds a template stays with Ops.
    if (system is String && system.contains('{{')) return null;
    return <String, dynamic>{
      // The bundle form names the model step `prompt`.
      'type': 'prompt',
      'prompt': _string((prompt as String?) ?? '', scope),
      if (system != null) 'systemPrompt': system as String,
      if (temperature != null) 'temperature': (temperature as num).toDouble(),
      'maxTokens': (maxTokens as int?) ?? 2000,
      'extractClaims': 'none',
    };
  }

  /// A `fact.query` step as a call of the host tool `knowledge_fact_list`
  /// (the same read, in this project's graph, answering the same map). The
  /// workspace has to be known here — named by the step, or the one the run is
  /// for — because the tool's own default is not the step's.
  static Map<String, dynamic>? _nativeFactQuery(ActionStep step, _Scope scope) {
    if (step.kind != 'fact.query') return null;
    final named = step.inputs['workspaceId'] ?? step.data['workspaceId'];
    if (named != null && named is! String) return null;
    if (named == null && scope.workspaceId.isEmpty) return null;
    return <String, dynamic>{
      'type': 'tool',
      'tool': 'knowledge_fact_list',
      'args': <String, dynamic>{
        'workspaceId':
            named == null
                ? _literal(scope.workspaceId)
                : _string(named as String, scope),
        if (step.inputs.containsKey('types'))
          'types': _value(step.inputs['types'], scope),
        if (step.inputs.containsKey('limit'))
          'limit': _value(step.inputs['limit'], scope),
      },
    };
  }

  /// The browser operation a `browser` step names, when it names one plainly
  /// (a fixed word, not a template). A step without one keeps going through
  /// the Ops step, which fails it the way it always has.
  static String? _browserOperation(ActionStep step) {
    if (step.kind != 'browser') return null;
    final op = step.data['operation'] ?? step.inputs['operation'];
    if (op is! String || op.isEmpty || op.contains('{{')) return null;
    return op;
  }

  /// Converts a value at any depth. Strings carry the templates.
  static dynamic _value(dynamic v, _Scope scope) {
    if (v is String) return _string(v, scope);
    if (v is Map) {
      return <String, dynamic>{
        for (final e in v.entries) '${e.key}': _value(e.value, scope),
      };
    }
    if (v is List) return <dynamic>[for (final e in v) _value(e, scope)];
    return v;
  }

  static final RegExp _template = RegExp(r'\{\{\s*([^}]+)\s*\}\}');

  /// One Ops string → one kernel string. The result is always text, like the
  /// Ops renderer: a string that would be exactly one `${…}` (which the kernel
  /// renders with the value's own type) gets an empty template appended.
  static String _string(String text, _Scope scope) {
    final out = StringBuffer();
    var last = 0;
    var templates = 0;
    for (final m in _template.allMatches(text)) {
      var before = text.substring(last, m.start);
      // A backslash right in front of a template would read as `\$`, an
      // escaped dollar sign, and swallow the template. Those backslashes go
      // into an expression of their own.
      var slashes = 0;
      while (before.endsWith(r'\')) {
        before = before.substring(0, before.length - 1);
        slashes += 1;
      }
      out.write(_literal(before));
      if (slashes > 0) {
        out.write('\${"${r'\\' * slashes}"}');
      }
      out.write(_expression(m.group(1)!.trim(), scope));
      templates += 1;
      last = m.end;
    }
    out.write(_literal(text.substring(last)));
    final rendered = out.toString();
    if (templates > 0 && _isSingleTemplate(rendered)) {
      return "$rendered\${''}";
    }
    return rendered;
  }

  /// Text that must come out exactly as written. The kernel starts a template
  /// at `${` and reads `\$` as a literal dollar sign; a backslash is only
  /// special in front of a `$`, so escaping the `$` alone is enough (a
  /// literal `\$` becomes `\\$`: a plain backslash, then an escaped dollar).
  static String _literal(String s) => s.replaceAll(r'$', r'\$');

  static bool _isSingleTemplate(String s) {
    if (!s.startsWith(r'${') || !s.endsWith('}')) return false;
    var depth = 0;
    String? quote;
    for (var i = 2; i < s.length; i++) {
      final c = s[i];
      if (quote != null) {
        if (c == r'\') {
          i += 1;
        } else if (c == quote) {
          quote = null;
        }
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '{') {
        depth += 1;
      } else if (c == '}') {
        if (depth == 0) return i == s.length - 1;
        depth -= 1;
      }
    }
    return false;
  }

  /// `{{ path }}` → a kernel expression template. Ops reads a dotted path out
  /// of `in`, `step`, `actor` and `workspace`; anything else is empty.
  static String _expression(String path, _Scope scope) {
    final parts = path.split('.');
    final root = parts.first;
    final rest = parts.skip(1).toList();
    switch (root) {
      case 'actor':
        return rest.isEmpty ? _literal(scope.actorId) : '';
      case 'workspace':
        return rest.isEmpty ? _literal(scope.workspaceId) : '';
      case 'in':
        if (rest.isEmpty) {
          throw SkillConversionRefused('a template reads the whole input map');
        }
        return '\${get(inputs, ${_path(rest)})}';
      case 'step':
        if (rest.isEmpty) {
          throw SkillConversionRefused('a template reads the whole step map');
        }
        final id = scope.outputs[rest.first];
        if (id == null) return ''; // not produced yet: empty, as in Ops.
        if (scope.llmSteps.contains(id)) {
          // The kernel's llm step answers the text alone; Ops' map also holds
          // usage, model and source, which only the Ops step can give.
          if (rest.length == 2 && rest[1] == 'text') {
            return '\${steps.$id.result}';
          }
          throw SkillConversionRefused(
            'a template reads more than the text of an llm answer',
          );
        }
        // `step.name` alone is the whole answer of that step.
        if (rest.length == 1) return '\${steps.$id.result}';
        return '\${get(steps.$id.result, ${_path(rest.skip(1).toList())})}';
      default:
        return '';
    }
  }

  /// A path as one string literal for the kernel's `get(object, "a.b.c")`.
  /// Ops reads a path by splitting it at the dots and descending only through
  /// maps — a list, a string or a number ends the walk with nothing. `get`
  /// does exactly that, whereas the kernel's own `.member` / `[index]` would
  /// answer for lists (`items.0`, `items.length`) and strings.
  static String _path(List<String> keys) {
    for (final k in keys) {
      if (k.isEmpty) {
        throw SkillConversionRefused('a template path has an empty part');
      }
    }
    final text = keys.join('.');
    return '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }
}

class _Scope {
  _Scope({required this.actorId, required this.workspaceId});
  final String actorId;
  final String workspaceId;

  /// Step `output` name → the kernel step id that last produced it.
  final Map<String, String> outputs = <String, String>{};

  /// Ids of the steps the kernel runs as its own `llm` step.
  final Set<String> llmSteps = <String>{};
}

/// The kernel's tool port for one skill run: it answers [kOpsStepTool] by
/// running the step with the Ops step implementation and nothing else.
class OpsStepPort implements bundle.McpPort {
  OpsStepPort(this._run, this._browser, this._factList);

  final Future<Map<String, dynamic>> Function(ActionStep step) _run;

  /// Calls `browser.<operation>` on the host and decodes the answer the way
  /// the Ops browser step always has.
  final Future<Map<String, dynamic>> Function(
    String operation,
    Map<String, dynamic> inputs,
  )
  _browser;

  /// Calls the host tool `knowledge_fact_list`.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> args)
  _factList;

  @override
  Future<bundle.ToolResult> callTool(
    String name,
    Map<String, dynamic> arguments, {
    String? serverId,
  }) async {
    if (name.startsWith('browser.')) {
      return bundle.ToolResult.success(
        await _browser(name.substring('browser.'.length), arguments),
      );
    }
    if (name == 'knowledge_fact_list') {
      return bundle.ToolResult.success(await _factList(arguments));
    }
    if (name != kOpsStepTool) {
      throw StateError(
        'Ops skill steps call only $kOpsStepTool, browser.* and knowledge_fact_list, not "$name"',
      );
    }
    Map<String, dynamic> map(Object? v) =>
        v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    final result = await _run(
      ActionStep(
        kind: '${arguments['kind']}',
        inputs: map(arguments['inputs']),
        data: map(arguments['data']),
      ),
    );
    return bundle.ToolResult.success(result);
  }

  @override
  Future<bundle.ResourceContent> readResource(String uri, {String? serverId}) =>
      throw UnsupportedError('Ops skill steps read no resources');

  @override
  Future<List<bundle.ToolInfo>> listTools({String? serverId}) async =>
      const <bundle.ToolInfo>[];

  @override
  Future<List<bundle.ResourceInfo>> listResources({String? serverId}) async =>
      const <bundle.ResourceInfo>[];

  @override
  Future<bundle.PromptTemplate?> getPrompt(
    String name, {
    String? serverId,
    Map<String, dynamic>? arguments,
  }) async => null;

  @override
  Future<bool> isConnected({String? serverId}) async => true;

  @override
  Stream<bundle.ResourceContent>? subscribeResource(
    String uri, {
    String? serverId,
  }) => null;
}

/// The kernel's LLM port for one skill run. It does not choose a provider: the
/// Ops completion rule does ([complete]), and this port only carries the
/// request across and remembers the answer in Ops' own shape.
class OpsLlmPort extends bundle.LlmPort {
  OpsLlmPort(this._complete);

  final Future<Map<String, dynamic>> Function({
    required String prompt,
    String? systemPrompt,
    double? temperature,
    required int maxTokens,
  })
  _complete;

  /// The answer of the most recent completion: `{text, usage, model, source}`
  /// (`{text, source}` for sampling).
  Map<String, dynamic>? lastAnswer;

  @override
  bundle.LlmCapabilities get capabilities =>
      const bundle.LlmCapabilities.minimal();

  @override
  Future<bundle.LlmResponse> complete(bundle.LlmRequest request) async {
    String? system;
    String prompt = '';
    for (final m in request.messages ?? const <bundle.LlmMessage>[]) {
      if (m.role == 'system') system ??= m.content;
      if (m.role == 'user') prompt = m.content;
    }
    final answer = await _complete(
      prompt: prompt,
      systemPrompt: system,
      temperature: request.temperature,
      maxTokens: request.maxTokens ?? 2000,
    );
    lastAnswer = answer;
    return bundle.LlmResponse(content: '${answer['text']}');
  }

  @override
  Future<List<double>> embed(String text) async =>
      throw UnsupportedError('Ops skill steps do not embed');
}

/// A converted skill, built and ready to run on a fresh kernel skill runtime.
/// Nothing is shared between runs: the registry and runtime live for this one.
///
/// Building can fail (an expression the kernel refuses); running must not be
/// retried elsewhere, because by then steps may already have had effects.
/// Callers therefore build first and only then decide which engine runs.
class PreparedKernelRun {
  PreparedKernelRun._(this._conversion, this._runtime, this._llm);

  final OpsConversion _conversion;
  final ks.SkillRuntime _runtime;
  final OpsLlmPort _llm;

  bundle.SkillModule get _module => _conversion.module;

  static Future<PreparedKernelRun> build(
    OpsConversion conversion, {
    required Future<Map<String, dynamic>> Function(ActionStep step) runStep,
    required Future<Map<String, dynamic>> Function(
      String operation,
      Map<String, dynamic> inputs,
    )
    runBrowser,
    required Future<Map<String, dynamic>> Function(Map<String, dynamic> args)
    listFacts,
    required Future<Map<String, dynamic>> Function({
      required String prompt,
      String? systemPrompt,
      double? temperature,
      required int maxTokens,
    })
    complete,
  }) async {
    final registry = ks.MemorySkillRegistry();
    await registry.registerSkill(ks.skillBundleFromModule(conversion.module));
    final llm = OpsLlmPort(complete);
    return PreparedKernelRun._(
      conversion,
      ks.SkillRuntime(
        registry: registry,
        ports: ks.SkillPorts(
          llm: llm,
          mcp: OpsStepPort(runStep, runBrowser, listFacts),
        ),
      ),
      llm,
    );
  }

  Future<Map<String, dynamic>> run(
    Map<String, dynamic> inputs, {
    String? actorId,
    String? workspaceId,
  }) async {
    if (_module.procedures.single.steps.isEmpty) return <String, dynamic>{};
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final result = await _runtime.runProcedure(
      _module.id,
      'default',
      ks.SkillContext(
        contextId: 'ops-$stamp',
        skillId: _module.id,
        runId: 'ops-$stamp',
        traceId: 'ops-$stamp',
        request: _module.id,
        workspaceId: workspaceId ?? '',
        asOf: DateTime.now(),
        inputs: inputs,
        userId: actorId,
        activeSkills: <String>[_module.id],
      ),
    );
    final out = result.output;
    // A skill that ends on an `llm` step answers the way Ops always has.
    if (_conversion.endsWithLlm) {
      return Map<String, dynamic>.from(
        _llm.lastAnswer ?? <String, dynamic>{'text': '$out'},
      );
    }
    return out is Map ? Map<String, dynamic>.from(out) : <String, dynamic>{};
  }
}
