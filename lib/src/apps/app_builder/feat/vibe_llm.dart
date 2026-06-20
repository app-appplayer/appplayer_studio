import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:mcp_llm/mcp_llm.dart'
    show ClaudeProvider, LlmConfiguration, LlmMessage, LlmRequest, LlmToolCall;

import '../core/patch_pipeline.dart';
import '../core/types.dart';
import '../infra/server_bootstrap.dart' show SamplingMessage, SamplingResult;
import '../infra/vibe_settings.dart';
import 'build_tools.dart';
import 'file_tools.dart';

/// Bridges [VibeChatController]'s `send` callback to a real Claude
/// provider from `mcp_llm`. Optionally drives a tool-use loop: when a
/// [PatchPipeline] is wired in, the LLM can call an `apply_patch` tool
/// to mutate the canonical bundle, and each successful dispatch is
/// streamed back to the chat as an `assistant.patch` card via
/// [onToolDispatched].
///
/// The adapter holds a single conversation history and rebuilds the
/// underlying provider when the API key / model / endpoint settings
/// change.
class VibeLlmAdapter {
  VibeLlmAdapter(
    VibeSettings settings, {
    PatchPipeline? pipeline,
    void Function(ChatTurn turn)? onToolDispatched,
  }) : _settings = settings,
       _pipeline = pipeline,
       _onToolDispatched = onToolDispatched;

  VibeSettings _settings;
  PatchPipeline? _pipeline;
  void Function(ChatTurn turn)? _onToolDispatched;
  ClaudeProvider? _provider;
  String? _providerKey;
  final List<LlmMessage> _history = <LlmMessage>[];

  /// Returns a one-line description of the user's current selection
  /// (focused layer / page or component / widget path) so the model
  /// can resolve "this widget" referents in user prompts. Set by the
  /// shell; null disables the hint.
  String Function()? _selectionContext;

  /// Wire the selection-context provider. Called from the shell once
  /// it has settled on its initial selection state.
  void bindSelectionContext(String Function() provider) {
    _selectionContext = provider;
  }

  /// Sandbox dispatcher for file-level tools (write/edit/delete/read/list).
  /// Bound by the shell whenever the active project changes; null when
  /// no project is open — the file tools are then absent from the
  /// schema published to the model.
  FileToolsDispatcher? _fileTools;

  /// Wire the project-rooted file dispatcher. Pass null to detach
  /// (e.g. when closing the project).
  void bindFileTools(FileToolsDispatcher? dispatcher) {
    _fileTools = dispatcher;
  }

  /// Dispatcher for build-level tools (pack_bundle, run_shell,
  /// read_build_guide, project_info). Bound by the shell once a
  /// project is open. Null disables the tool surface entirely.
  BuildToolsDispatcher? _buildTools;

  void bindBuildTools(BuildToolsDispatcher? dispatcher) {
    _buildTools = dispatcher;
  }

  /// Server-initiated sampling fallback: when no internal API key is
  /// configured, the adapter delegates to the connected MCP host's
  /// LLM via `sampling/createMessage`. Wired by main.dart with a
  /// `ServerBootstrap.requestSamplingFromHost` closure. Returning null
  /// from the closure means no sampling-capable host is connected.
  ///
  /// The closure forwards messages + system prompt + tool definitions
  /// (so the host's LLM can drive the same vibe tools the internal
  /// LLM uses) and returns a typed [SamplingResult] with parsed text
  /// and tool_use blocks. Hosts that ignore the `tools` field still
  /// produce a text-only response.
  Future<SamplingResult?> Function({
    required List<SamplingMessage> messages,
    String? systemText,
    List<Map<String, dynamic>>? tools,
  })?
  _samplingFn;

  void bindSampling(
    Future<SamplingResult?> Function({
      required List<SamplingMessage> messages,
      String? systemText,
      List<Map<String, dynamic>>? tools,
    })
    fn,
  ) {
    _samplingFn = fn;
  }

  /// Replace the settings the next [send] call will use.
  void update(VibeSettings settings) {
    _settings = settings;
  }

  /// Wire (or rewire) the patch pipeline + per-tool callback. Called
  /// from the shell once the project is open so the LLM can mutate the
  /// canonical via tool-use.
  void bindToolDispatch({
    required PatchPipeline pipeline,
    required void Function(ChatTurn turn) onToolDispatched,
  }) {
    _pipeline = pipeline;
    _onToolDispatched = onToolDispatched;
  }

  /// Implements [VibeChatController.send].
  Future<ChatTurn> send(String userInput) async {
    final key = _settings.llmApiKey;
    if (key == null || key.isEmpty) {
      // No internal LLM. Two distinct paths exist for the user:
      //
      // (a) Drive vibe **directly from the host's native UI** — every
      //     vibe tool (vibe_layer_patch / vibe_file_* / vibe_build_* /
      //     vibe_convert_*) is already published over MCP, and hosts
      //     like Claude Desktop expose them with their own tool-use
      //     UI. This is the canonical path: full tool access, no extra
      //     wiring on vibe's side.
      //
      // (b) Use vibe's chat panel anyway. We delegate text completion
      //     to the host's LLM via `sampling/createMessage`. The reply
      //     is free-form text — the LLM can describe a plan, but tool
      //     dispatch happens through the host's tool-use UI (path a),
      //     not through this code path.
      //
      // Either way the user is not blocked. We just wire (b) so the
      // chat panel stays useful when the user prefers a single pane.
      final fn = _samplingFn;
      if (fn != null) {
        try {
          final reply = await _runSamplingTurn(fn, userInput);
          if (reply != null) return reply;
        } catch (e) {
          return ChatTurn(
            role: 'assistant.error',
            text: 'Host sampling failed: $e',
          );
        }
      }
      return ChatTurn(
        role: 'assistant',
        text:
            'No LLM API key set. You can still drive vibe in two '
            'ways: (a) talk to your MCP host (Claude Desktop, MCP '
            'Inspector) directly — every vibe.* tool is already '
            'exposed there; or (b) set an API key in Settings → LLM '
            "to use vibe's own chat panel. (Sampling fallback through "
            'the host is also available if the host advertises the '
            '`sampling` capability.)',
      );
    }
    final provider = await _ensureProvider(key);
    final tools = <Map<String, dynamic>>[
      if (_pipeline != null) ..._toolDefinitions,
      if (_fileTools != null) ...FileToolsDispatcher.toolDefinitions,
      if (_buildTools != null) ...BuildToolsDispatcher.toolDefinitions,
    ];
    final selection = _selectionContext?.call();
    final systemInstruction =
        selection == null || selection.isEmpty
            ? _systemPrompt
            : '$_systemPrompt\n\nCurrent user selection: $selection';
    try {
      _history.add(LlmMessage.user(userInput));
      // Multi-round agent loop: keep calling the LLM until it stops
      // emitting tool calls (or we hit the safety cap). Each round:
      //  1. provider.complete(history)
      //  2. dispatch any tool calls — each successful dispatch fires
      //     its own patch card into the chat feed via the host
      //     callback so the user sees changes streaming in
      //  3. append tool results to history
      //  4. if the LLM had tool calls AND wanted to keep going, loop
      //     so it can analyse the results and either call more tools
      //     or write a final answer
      // Without this loop the LLM only got one shot — it would call a
      // tool, say "i'll check", and the conversation would end before
      // any actual analysis.
      // Lower than the previous 12 because each round re-sends the
      // full history + tool definitions; 30K input-tokens/min rate
      // limits trip otherwise. 6 covers most "read → patch → verify"
      // chains; deeper sessions still complete across user turns.
      const maxRounds = 6;
      var totalSuccess = 0;
      var totalFail = 0;
      String? lastText;
      for (var round = 0; round < maxRounds; round++) {
        final roundRequest = LlmRequest(
          prompt: round == 0 ? userInput : '',
          history: List<LlmMessage>.from(_history),
          parameters: <String, dynamic>{
            if (tools.isNotEmpty) 'tools': tools,
            'max_tokens': 4096,
          },
        ).withSystemInstruction(systemInstruction);
        final response = await provider.complete(roundRequest);
        final toolCalls = response.toolCalls ?? const <LlmToolCall>[];
        lastText = response.text;
        if (toolCalls.isEmpty || _pipeline == null) {
          _history.add(LlmMessage.assistant(response.text));
          if (round == 0) {
            return ChatTurn(role: 'assistant', text: response.text);
          }
          break;
        }
        _history.add(LlmMessage.assistant(response.text));
        for (final tc in toolCalls) {
          final result = await _dispatchTool(tc);
          if (result.success) {
            totalSuccess++;
          } else {
            totalFail++;
          }
          _onToolDispatched?.call(result.turn);
          _history.add(
            LlmMessage.tool(
              tc.name,
              result.resultText,
              toolCallId: tc.id,
              arguments: tc.arguments,
            ),
          );
        }
        // Loop back — let the LLM see the tool results and either
        // call more tools or write a final analysis.
      }
      // Wrap-up turn: prefer the model's last free-text response, fall
      // back to a synthetic summary so the chat never ends silently.
      final wrap =
          (lastText ?? '').trim().isNotEmpty
              ? lastText!
              : 'Applied $totalSuccess change${totalSuccess == 1 ? '' : 's'}'
                  '${totalFail > 0 ? ' ($totalFail failed)' : ''}.';
      return ChatTurn(role: 'assistant', text: wrap);
    } catch (e) {
      final msg = e.toString();
      // Surface rate-limit (HTTP 429) as a friendly note so the user
      // doesn't get a wall of stack trace. mcp_llm exhausts its own
      // retry budget before throwing here — at that point we know it
      // really is a quota issue, not a transient hiccup.
      if (msg.contains('429') || msg.contains('rate_limit_error')) {
        return ChatTurn(
          role: 'assistant.error',
          text:
              'Anthropic per-minute token limit (30K) exceeded. Wait '
              'about a minute and retry, or switch to a smaller model '
              '(Sonnet 4.6 / Haiku 4.5) in Settings. When a single turn '
              'stacks multiple rounds (read+patch+verify), every send '
              'replays the full history — an occasional conversation '
              'clear helps.',
        );
      }
      return ChatTurn(role: 'assistant.error', text: 'LLM request failed: $e');
    }
  }

  /// Sampling-fallback turn: mirror the internal LLM agent loop one
  /// round, but route the completion through the host's LLM via
  /// `sampling/createMessage`. Returns null when the host has no
  /// sampling capability so the caller can fall through to the static
  /// guidance message.
  Future<ChatTurn?> _runSamplingTurn(
    Future<SamplingResult?> Function({
      required List<SamplingMessage> messages,
      String? systemText,
      List<Map<String, dynamic>>? tools,
    })
    fn,
    String userInput,
  ) async {
    final tools = <Map<String, dynamic>>[
      if (_pipeline != null) ..._toolDefinitionsAsMcp,
      if (_fileTools != null)
        ..._mcpToolDefs(FileToolsDispatcher.toolDefinitions),
      if (_buildTools != null)
        ..._mcpToolDefs(BuildToolsDispatcher.toolDefinitions),
    ];
    final selection = _selectionContext?.call();
    final systemInstruction =
        selection == null || selection.isEmpty
            ? _systemPrompt
            : '$_systemPrompt\n\nCurrent user selection: $selection';
    final messages = <SamplingMessage>[
      // Replay history as plain text only — sampling responses are
      // typed (text + tool_use blocks); we don't reconstruct prior
      // tool_use rounds (single-shot like the internal LLM path).
      for (final m in _history) _samplingMessageFromHistory(m),
      SamplingMessage.user(userInput),
    ];
    final result = await fn(
      messages: messages,
      systemText: systemInstruction,
      tools: tools.isEmpty ? null : tools,
    );
    if (result == null) return null;
    _history.add(LlmMessage.user(userInput));
    final toolCalls = result.toolCalls;
    if (toolCalls.isEmpty) {
      _history.add(LlmMessage.assistant(result.text));
      return ChatTurn(role: 'assistant', text: result.text);
    }
    _history.add(LlmMessage.assistant(result.text));
    var successCount = 0;
    var failCount = 0;
    for (final tc in toolCalls) {
      final call = LlmToolCall(id: tc.id, name: tc.name, arguments: tc.input);
      final dispatch = await _dispatchTool(call);
      if (dispatch.success) {
        successCount++;
      } else {
        failCount++;
      }
      _onToolDispatched?.call(dispatch.turn);
      _history.add(
        LlmMessage.tool(
          tc.name,
          dispatch.resultText,
          toolCallId: tc.id,
          arguments: tc.input,
        ),
      );
    }
    final wrap =
        result.text.trim().isNotEmpty
            ? result.text
            : 'Applied $successCount change${successCount == 1 ? '' : 's'}'
                '${failCount > 0 ? ' ($failCount failed)' : ''}.';
    return ChatTurn(role: 'assistant', text: wrap);
  }

  /// Re-shape an internal [LlmMessage] for inclusion in a sampling
  /// request as a plain text message. Tool-result history rounds get
  /// flattened to text since sampling messages don't carry typed tool
  /// blocks one-to-one with the internal LLM provider's wire format.
  static SamplingMessage _samplingMessageFromHistory(LlmMessage m) {
    final role = m.role;
    final text = m.toString();
    if (role == 'assistant') return SamplingMessage.assistant(text);
    return SamplingMessage.user(text);
  }

  /// Internal dispatcher tools (file.* / build.*) ship as Anthropic-
  /// shaped maps with `parameters`. MCP sampling expects the MCP
  /// tool-list shape (`name` + `description` + `inputSchema`).
  /// Translate one-to-one.
  static List<Map<String, dynamic>> _mcpToolDefs(
    List<Map<String, dynamic>> internal,
  ) {
    return <Map<String, dynamic>>[
      for (final t in internal)
        <String, dynamic>{
          'name': t['name'],
          'description': t['description'],
          'inputSchema': t['parameters'] ?? <String, dynamic>{},
        },
    ];
  }

  /// MCP-shape view of [_toolDefinitions] for sampling.
  static List<Map<String, dynamic>> get _toolDefinitionsAsMcp =>
      _mcpToolDefs(_toolDefinitions);

  /// Dispatch a single tool call. Public for tests; production callers
  /// reach this via [send].
  @visibleForTesting
  Future<ChatTurn> debugDispatch(LlmToolCall call) async {
    final r = await _dispatchTool(call);
    return r.turn;
  }

  Future<_DispatchResult> _dispatchTool(LlmToolCall call) async {
    // File-tool branch first — these don't require the canonical
    // pipeline. The dispatcher is null when no project is open, in
    // which case the tools were not advertised to the model and we
    // fall through to the apply_patch error path.
    if (FileToolsDispatcher.claimedTools.contains(call.name)) {
      final fileTools = _fileTools;
      if (fileTools == null) {
        return _DispatchResult.failure(
          toolName: call.name,
          message: 'File tools not wired (no project open)',
        );
      }
      try {
        final result = await fileTools.dispatch(call.name, call.arguments);
        if (result == null) {
          return _DispatchResult.failure(
            toolName: call.name,
            message: 'Unknown file tool: ${call.name}',
          );
        }
        if (!result.success) {
          return _DispatchResult.failure(
            toolName: call.name,
            message: result.message,
          );
        }
        return _DispatchResult.fileSuccess(toolName: call.name, result: result);
      } catch (e) {
        return _DispatchResult.failure(
          toolName: call.name,
          message: 'file dispatch failed: $e',
        );
      }
    }
    // Build-tool branch — pack_bundle / run_shell / read_build_guide /
    // project_info. Same fall-through rules as file tools.
    if (BuildToolsDispatcher.claimedTools.contains(call.name)) {
      final buildTools = _buildTools;
      if (buildTools == null) {
        return _DispatchResult.failure(
          toolName: call.name,
          message: 'Build tools not wired (no project open)',
        );
      }
      try {
        final result = await buildTools.dispatch(call.name, call.arguments);
        if (result == null) {
          return _DispatchResult.failure(
            toolName: call.name,
            message: 'Unknown build tool: ${call.name}',
          );
        }
        if (!result.success) {
          return _DispatchResult.failure(
            toolName: call.name,
            message: result.message,
          );
        }
        return _DispatchResult.buildSuccess(
          toolName: call.name,
          result: result,
        );
      } catch (e) {
        return _DispatchResult.failure(
          toolName: call.name,
          message: 'build dispatch failed: $e',
        );
      }
    }
    final pipeline = _pipeline;
    if (pipeline == null) {
      return _DispatchResult.failure(
        toolName: call.name,
        message: 'Pipeline not wired',
      );
    }
    if (call.name != 'apply_patch') {
      return _DispatchResult.failure(
        toolName: call.name,
        message: 'Unknown tool: ${call.name}',
      );
    }
    try {
      final args = call.arguments;
      final layerName = args['layer'] as String?;
      final layer = _decodeLayer(layerName);
      if (layer == null) {
        return _DispatchResult.failure(
          toolName: call.name,
          message: 'Unknown layer: $layerName',
        );
      }
      final rawOps = args['ops'];
      if (rawOps is! List) {
        return _DispatchResult.failure(
          toolName: call.name,
          message: 'ops must be a list',
        );
      }
      final ops = <PatchOp>[];
      for (final raw in rawOps) {
        if (raw is! Map) continue;
        final op = raw['op'] as String?;
        final path = raw['path'] as String?;
        if (op == null || path == null) continue;
        ops.add(PatchOp(op: op, path: path, value: raw['value']));
      }
      if (ops.isEmpty) {
        return _DispatchResult.failure(
          toolName: call.name,
          message: 'no valid ops',
        );
      }
      final summary =
          (args['summary'] as String?)?.trim().isNotEmpty == true
              ? args['summary'] as String
              : '$layerName patch (${ops.length} op${ops.length == 1 ? '' : 's'})';
      final result = await pipeline.apply(
        CanonicalPatch(
          layer: layer,
          ops: ops,
          originator: LlmOriginator(turnId: call.id ?? 'unknown'),
        ),
      );
      if (result is! PatchApplied) {
        final reason =
            (result as PatchRejected).report.errors.isNotEmpty
                ? result.report.errors.first.message
                : 'pipeline rejected';
        return _DispatchResult.failure(
          toolName: call.name,
          message: 'rejected: $reason',
          summary: summary,
        );
      }
      return _DispatchResult.success(
        toolName: call.name,
        summary: summary,
        layer: layer,
        fileCount: ops.length,
      );
    } catch (e) {
      return _DispatchResult.failure(
        toolName: call.name,
        message: 'dispatch failed: $e',
      );
    }
  }

  Future<ClaudeProvider> _ensureProvider(String apiKey) async {
    final model =
        _settings.llmModel?.trim().isNotEmpty == true
            ? _settings.llmModel!.trim()
            : 'claude-opus-4-7';
    final endpoint = _settings.llmEndpoint?.trim();
    final providerKey = '$apiKey|$model|${endpoint ?? ''}';
    if (_provider != null && _providerKey == providerKey) {
      return _provider!;
    }
    final config = LlmConfiguration(
      apiKey: apiKey,
      model: model,
      baseUrl: endpoint == null || endpoint.isEmpty ? null : endpoint,
    );
    final provider = ClaudeProvider(
      apiKey: apiKey,
      model: model,
      baseUrl: endpoint == null || endpoint.isEmpty ? null : endpoint,
      config: config,
    );
    await provider.initialize(config);
    _provider = provider;
    _providerKey = providerKey;
    return provider;
  }

  /// Drop the conversation history (e.g. when opening a different
  /// project, where the running app context has changed).
  void resetHistory() {
    _history.clear();
  }

  /// Replace the conversation history with the user / assistant turns
  /// from [turns]. System notes and error turns are skipped — only
  /// roles the LLM will recognise on the next request are kept.
  void seedHistory(Iterable<ChatTurn> turns) {
    _history.clear();
    for (final turn in turns) {
      if (turn.role == 'user') {
        _history.add(LlmMessage.user(turn.text));
      } else if (turn.role == 'assistant' || turn.role == 'assistant.patch') {
        _history.add(LlmMessage.assistant(turn.text));
      }
      // 'system', 'error', 'assistant.error' deliberately skipped.
    }
  }

  static LayerId? _decodeLayer(String? name) {
    if (name == null) return null;
    for (final id in LayerId.values) {
      if (id.name == name) return id;
    }
    return null;
  }

  /// The single MCP-style tool the LLM may call. RFC 6902 ops keep the
  /// surface small while letting the model drive any canonical
  /// mutation Properties / pages / theme can express.
  static const List<Map<String, dynamic>>
  _toolDefinitions = <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'apply_patch',
      'description':
          'Apply RFC 6902 patches to the canonical mcp_ui DSL bundle. Use this to '
          'add, modify, or remove pages, components, app metadata, theme '
          'tokens, or the dashboard. Each call is atomic; large changes '
          'should batch ops in a single call.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'layer': <String, dynamic>{
            'type': 'string',
            'enum': <String>[
              'appStructure',
              'theme',
              'components',
              'dashboard',
              'pages',
              'whole',
            ],
            'description':
                'Which editing layer the change targets. Drives validation + '
                'the chat-card colour stripe.',
          },
          'ops': <String, dynamic>{
            'type': 'array',
            'description':
                'RFC 6902 operations. Paths are JSON Pointers rooted at the '
                'canonical bundle, e.g. "/ui/title" or '
                '"/ui/pages/home".',
            'items': <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{
                'op': <String, dynamic>{
                  'type': 'string',
                  'enum': <String>['add', 'replace', 'remove'],
                },
                'path': <String, dynamic>{'type': 'string'},
                'value': <String, dynamic>{
                  'description':
                      'Required for add/replace; ignored for remove. Any '
                      'JSON value the spec accepts at this path.',
                },
              },
              'required': <String>['op', 'path'],
            },
          },
          'summary': <String, dynamic>{
            'type': 'string',
            'description':
                'One-line human-readable description of what this patch '
                'achieves. Shown on the chat patch card.',
          },
        },
        'required': <String>['layer', 'ops', 'summary'],
      },
    },
  ];
}

class _DispatchResult {
  _DispatchResult._({
    required this.success,
    required this.turn,
    required this.resultText,
  });

  factory _DispatchResult.success({
    required String toolName,
    required String summary,
    required LayerId layer,
    required int fileCount,
  }) {
    return _DispatchResult._(
      success: true,
      turn: ChatTurn(
        role: 'assistant.patch',
        text: summary,
        layer: layer,
        fileCount: fileCount,
      ),
      resultText: jsonEncode(<String, dynamic>{
        'ok': true,
        'summary': summary,
        'opsApplied': fileCount,
      }),
    );
  }

  /// Successful file-tool call. Surfaces the affected path + a short
  /// human label on the chat feed so the user sees vibe progressing
  /// through file writes during a build / generation task.
  factory _DispatchResult.fileSuccess({
    required String toolName,
    required FileToolResult result,
  }) {
    final label = result.path != null ? '$toolName ${result.path}' : toolName;
    return _DispatchResult._(
      success: true,
      turn: ChatTurn(
        role: 'assistant.patch',
        text: '$label — ${result.message}',
      ),
      resultText: encodeFileToolResult(result),
    );
  }

  /// Successful build-tool call (pack_bundle / run_shell / etc).
  factory _DispatchResult.buildSuccess({
    required String toolName,
    required BuildToolResult result,
  }) {
    final label = result.path != null ? '$toolName ${result.path}' : toolName;
    return _DispatchResult._(
      success: true,
      turn: ChatTurn(
        role: 'assistant.patch',
        text: '$label — ${result.message}',
      ),
      resultText: encodeBuildToolResult(result),
    );
  }

  factory _DispatchResult.failure({
    required String toolName,
    required String message,
    String? summary,
  }) {
    return _DispatchResult._(
      success: false,
      turn: ChatTurn(
        role: 'assistant.error',
        text: '${summary ?? toolName}: $message',
      ),
      resultText: jsonEncode(<String, dynamic>{'ok': false, 'error': message}),
    );
  }

  final bool success;
  final ChatTurn turn;
  final String resultText;
}

const String _systemPrompt = '''
You are vibe, an AI design assistant for mcp_ui DSL 1.3 bundles.

Vibe is a desktop tool where the user authors an mcp_ui Application:
manifest, app theme, pages, components (templates), and the dashboard.
The user edits via Properties; you assist conversationally — explain
the spec, propose layouts, and apply changes when the user asks.

SPEC-REQUIRED STRUCTURE — verify these are present whenever you
create or substantially restructure something. Missing required
fields produces a bundle that compiles but fails to render:

  Application  (/ui)
    type:          "application"   (never omit)
    title:         <string>        (default "Untitled App")
    initialRoute:  "/" or other    (must match a key in `routes`)
    routes:        { "/": "<pageId>", ... }   one entry per page
    pages:         { "<id>": Page, ... }
    templates:     { "<id>": Template, ... }  (optional, may be empty)
    theme:         {}                          (optional, see below)
    navigation:    NavigationConfig            (optional — drawer /
                                                bottomBar / rail / tabs
                                                chrome wrapping every
                                                page; `{type, items[]}`)
                                                + `style` (NavigationStyle
                                                — backgroundColor /
                                                indicatorColor / divider*
                                                / labelStyle / iconStyle
                                                / selectedColor /
                                                unselectedColor /
                                                elevation per 1.3.4 §5.4)
    i18n:          I18nConfig                  (optional — defaultLocale
                                                + locales[] + text /
                                                pluralization /
                                                numberFormat /
                                                dateFormat /
                                                textDirection per locale)
    services:      { <name>: ServiceDefinition } (optional — kind:
                                                polling|subscription,
                                                interval, tool, params,
                                                binding, onMessage,
                                                onError, autoStart)
    templateLibraries: [TemplateLibraryRef]    (optional — remote
                                                template library refs:
                                                `{uri, version?,
                                                integrity?}` per
                                                1.3.4 §9.11.1)

  Manifest  (/manifest) — bundle wrapper. Two distinct concerns:

    A. Bundle metadata (id / name / version / publisher / splash /
       permissions / localization / timestamps / screenshots).
       Authored at /ui/* and extracted to manifest at bundle pack
       time — never edited directly through vibe. Always go through
       /ui/title, /ui/publisher, /ui/splash, etc.

    B. Asset registry (/manifest/assets) — file-backed resources
       (image / font / audio / video / json / text) shipped with
       the bundle. Authored at registration time so widgets can
       reference them via bundle://<id>. THIS is edited from vibe
       (Assets layer + gallery + picker). It is the only /manifest
       surface that takes mutations during authoring.

    assets:   AssetSection (optional — file-backed asset registry)
              { schemaVersion, assets[
                  { id, type, path|contentRef, mimeType, hash, size }
                ] }
              type ∈ image / font / audio / video / json / text /
              file. `path` = in-bundle file (e.g. `assets/logo.png`)
              copied via vibe's file picker. `contentRef` is an
              AssetRef per spec — schemes: `https://`, `http://`,
              `data:`, `assets/`, `client://`.
              Widgets reference these entries via `bundle://<id>`.

  Page  (/ui/pages/<id>)
    type:    "page"
    title:   <string>
    content: <Widget>              (the root widget — required)
    state:   { ... }               (optional initial reactive state)

  Template  (/ui/templates/<id>)
    content: <Widget>              (root widget — required)
    props:   { <name>: <schema> }  (optional; declares inputs)

  Theme  (/ui/theme)
    preset:       optional (1.3.4 Phase 5) — `warm` / `cool` /
                  `sepia` / `mono` / `highContrast`. Curated content-
                  app base. Other theme.* fields layer overrides on top.
    color:        Material 3 color tokens (primary, onPrimary, …)
    typography:   M3 type scale (displayLarge…labelSmall)
    fonts:        optional (1.3.4 Phase 5) — `{ <family>: { weights:
                  {<value>: AssetRef}, variableAxes: [{tag, min, max,
                  default}], fallbacks: [<family>] } }`. Use
                  theme_font_set for atomic upserts.
    spacing / shape / elevation   (optional but conventional)
    Tokens are added incrementally via set_property; an empty theme
    is valid (runtime falls back to defaults).

  Widget — every node MUST have `type` (string). Per-widget required
  fields live in the schema. Call vibe_widget_describe(<type>) to
  see them before authoring an unfamiliar widget.

  Wiring rule: every page id MUST appear in routes — otherwise the
  page is unreachable. When you add a page, also set the route in
  the same logical step:
    1. set_property(/ui/pages, "<id>", {type:"page", title:"…",
                                         content:{...}})
    2. set_property(/ui/routes, "/<urlPath>", "<id>")
    (initialRoute is already "/" by default — only change it when
    the user wants a different landing route)

BUNDLE EDITING — USE SEMANTIC TOOLS, NOT raw JSON read/write:

Discovery (top-down):
  bundle_outline()                — manifest + app + theme summary +
                                    page list + template list +
                                    dashboard. THE entry point when
                                    you don't yet know what's there.
  get_section(section, id?)       — read full theme / app / manifest
                                    / dashboard, or one page /
                                    template by id. Use for tokens
                                    + metadata (non-widget data).
  tree_outline(scope?)            — flat list of every widget under
                                    `scope` (default `/ui`). Each
                                    entry: {path, type, label, depth,
                                    hasChildren?}. THE primary widget
                                    inspection tool.
  get_widget(path)                — full subtree of one widget.

Common questions → tool mapping (use as a quick lookup):
  "what pages?"
       → bundle_outline()           (read `pages` array)
  "is there a dashboard?"
       → bundle_outline()           (`dashboard` key absent = no)
  "what templates?"
       → bundle_outline()           (read `templates` array)
  "show me the theme"
       → get_section('theme')       (full token tree, even if empty)
  "what routes are wired?"
       → get_section('app')         (look at `routes` map)
  "what's in page X?"
       → get_section('pages', 'form')   ← full page incl. state +
                                          content (one call)
       OR tree_outline('/ui/pages/form')   ← flat widget tree only
  "second widget on the form page?"
       → tree_outline → pick path  →  get_widget(path)
  "what color is widget X?"
       → get_widget(path)           (read style.color)
  "draw me the tree"
       → tree_outline()             (default scope = /ui)
  "find every text using state.name"
       → find_widgets(type='button')        (or refersTo='state.name')
  "make every button filled / every text bold"
       → apply_to_each(type='button',
                       set={variant:'filled'}, dryRun?)
                                       (find + bulk set; cap=50;
                                       use scope to limit, set OR
                                       setDeep map of property→value.
                                       Pair with refersTo to scope to
                                       widgets bound to a state key.)
  "where is color #FF0000 used?"
       → find_widgets(refersTo='#FF0000')
  "search the bundle (e.g. Welcome text)"
       → search(query='Welcome')      (cross-cutting: page ids,
                                       template ids, route paths,
                                       asset ids, widget types /
                                       labels, text content,
                                       bindings; ranked exact >
                                       prefix > substring; cap 50.)
  "is everything wired? pre-build check"
       → check_wiring()             (orphans, missing targets,
                                     undefined state refs, unused
                                     templates — single call)
  "rename home page to dashboard"
       → rename_page(oldId='home', newId='dashboard')   (atomic;
                                     routes auto-updated)
  "rename heroCard template"
       → rename_template(oldId, newId)   (atomic — every `use`
                                     widget naming it gets rewritten)
  "rename state key state.count to ticker"
       → rename_state_key(oldKey, newKey, scope?='app'|'page:<id>')
                                     (every `{{state.<oldKey>}}`
                                     binding rewritten — whitespace
                                     and dotted accessors handled)
  "change route /about to /info"
       → rename_route(oldPath='/about', newPath='/info')
                                     (target page kept; updates
                                     /ui/routes + initialRoute +
                                     navigation.items[].route +
                                     `{{routes.<oldPath>}}` bindings)
  "DRY this card (extract to template)"
       → extract_template(widgetPath, templateId)      (atomic;
                                     original becomes a `use` widget)
  "inline this use"
       → inline_template(usePath)   (props are substituted)
  "duplicate home page as settings at /settings"
       → duplicate_page(srcId='home', newId='settings',
                        route='/settings')
  "create a new page / gallery page"
       → page_create(id, title?, route?, kind?, home?)
                                       (atomic — page entry +
                                       route + optional layout
                                       preset in one dispatch.
                                       route default `/<id>`. kind
                                       picks from layout_preset
                                       catalog. home=true sets
                                       initialRoute when unset.)
  "extract this widget to template"
       → extract_to_template(widgetPath, newTemplateId)
                                     (subtree → /ui/templates/<id>
                                     created + original site replaced
                                     with use:<id>. Inverse of
                                     inline_template.)
  "lint this page / deep nesting / empty container"
       → widget_lint(scope?)         (quality beyond a11y —
                                     deep_nesting, empty_container,
                                     long_text_leaf, redundant_wrapper,
                                     list_no_item_id.)
  "project dependency graph / pre-marketplace packaging analysis"
       → dependency_graph(topWidgets?)
                                     (page/template → routes/templates
                                     /assets/state/widgetTypes graph
                                     + invertedTemplates/Assets — for
                                     impact-scope assessment.)
  "find hardcoded colors / spacings / theme-token candidates"
       → tokenization_audit(scope?)
                                     (color hex / spacing 4·8·12·16·
                                     20·24·32·40·48 / radius 4·8·12·
                                     16·24·28 → token suggestions
                                     included. Use `scope` to narrow
                                     to one page.)
  "where is template:hero used? find usages"
       → find_references(target='template:hero')
                                     (every use:hero location + per-
                                     container grouping. Use before
                                     rename/delete to gauge impact.)
  "who reads state 'counter' / where is asset bgImage used?"
       → find_references(target='state:home.counter')
       → find_references(target='asset:bgImage')
       → find_references(target='route:/settings')
                                     (4-kind unified — IDE Find
                                     Usages equivalent.)
  "what did I change? recent history / show only theme edits"
       → undo_history(limit?, originator?, pathPrefix?)
                                     (history.jsonl most-recent first.
                                     Real originator values are
                                     llm.semantic / gui.editor etc. —
                                     discover by calling without a
                                     filter once. Scope with e.g.
                                     pathPrefix='/ui/theme'.)
  "route integrity check / unreachable page / is initialRoute right?"
       → route_audit()
                                     (page ↔ route ↔ initialRoute
                                     focused audit — narrower than
                                     health_check and actionable. Each
                                     finding ships with a fix
                                     suggestion.)
  "apply this RFC 6902 patch (mixed layers)"
       → diff_apply(ops: [...])     (per-op layer auto-infer; ops
                                     sharing layer dispatched
                                     together. When only one layer is
                                     touched, layer_patch is more
                                     explicit.)
  "audit state usage on the form page"
       → state_usage(pageId='form')   (declared vs referenced
                                       matrix; unused / undefined
                                       summary)
  "seed missing state keys automatically"
       → state_propose(pageId, apply?)
                                       (walks bindings, reports keys
                                       not declared in /ui/state or
                                       page state. apply=true seeds
                                       them null at the page level.)
  "what depends on this widget?"
       → binding_dependencies(path)   (state keys, templates,
                                       routes, external refs)
  "set primary color to #5B7CFA and theme around it"
       → apply_theme_preset(seedColor='#5B7CFA', mode?)
                                       (full M3 token set in one
                                       call — typography + spacing
                                       + shape included)
  "wrap this widget with X / add padding"
       → apply_recipe(name, args, dryRun?)
                                       (catalog: wrap_with_card /
                                       wrap_with_padding / wrap_with
                                       _hero / wrap_with_safearea /
                                       add_floating_action / add_
                                       loading_state. Each takes its
                                       own `args` map; see tool's
                                       description for shapes.)
  "scaffold a settings / form page skeleton"
       → apply_layout_preset(pageId, kind)
                                       (utility: hero / cardList /
                                       form / settings · 1.3.4
                                       content-app: gallery /
                                       magazine / carousel /
                                       playlist / landing)
  "unify motion on this page / apply M3 motion"
       → animation_preset(pageId, kind, dryRun?)
                                       (kind ∈ emphasized / standard
                                       / decelerate / accelerate —
                                       sets duration + curve on
                                       every animated* widget so
                                       the page reads as one motion
                                       language)
  "validate everything before build" / "is the bundle ready?"
       → validate_bundle()             (spec + wiring in one shot)
  "full check / health check / shipping ready?"
       → health_check()                (spec + wiring + a11y +
                                        asset audit + per-page state
                                        usage + dead theme tokens
                                        — single call returns status:
                                        pass / warn / fail + counts +
                                        details. Use this instead of
                                        chaining the sub-tools.)
  "can we ship + auto-fix" / "graduate this bundle"
       → release_check(dryRun?)         (multi-stage: health → asset_
                                        audit(apply) → a11y_quick_
                                        fix → final health. Returns
                                        {ready, before, after,
                                        steps[], remaining}. Use as
                                        the last call before ship.)
  "what grade is this bundle / quality score"
       → grade()                        (letter A-F + 5-axis rubric:
                                        validity / a11y / assets /
                                        state / tokens. N/A when
                                        empty bundle.)
  "show me unsaved changes" / "pending diff" / "what would save?"
       → pending_diff()                 (RFC 6902 ops + summary
                                        tree comparing canonical
                                        with on-disk committed bundle)
  "add a drawer" / "make a bottom tab bar" / "show navigation"
       → get_section('navigation')     (read current chrome config)
       → set_property(/ui/navigation, "type", "drawer")
       → set_property(/ui/navigation, "items", [{label, route, icon},…])
                                       (chrome lives at /ui/navigation,
                                       NavigationConfig schema —
                                       drawer/bottomBar/rail/tabs)
ICON VALUE FORMS (spec: widgets/display/icon.yaml §examples) —
five source forms accepted by `icon`:
   1. Material name             icon: "home"
   2. Codepoint object          icon: {codepoint:59530, fontFamily?:…}
   3. URL (raster or SVG)       icon: "https://…/icon.svg"
   4. Bundle SVG (pubspec asset) icon: "assets/icons/heart.svg"
   5. Inline data URI           icon: "data:image/svg+xml;base64,…"

The asset registry (/manifest/assets) covers file-backed types —
image / font / audio / video / json / text — and is referenced from
widgets via `bundle://<id>`. Material icons have no file to ship,
so they are referenced inline using form 1.
  "what assets are registered?"
       → get_section('assets')         (registry list)
  "where is this icon used?"
       → find_widgets(refersTo='bundle://menuLogo')
  "add Korean" / "register ko-KR locale"
       → i18n_locale_add(tag='ko-KR', setAsDefault?)
                                       (BCP-47 tag — appended to
                                       /ui/i18n/locales; setAsDefault
                                       also pins /ui/i18n/defaultLocale)
  "remove ko locale" / "remove locale ko"
       → i18n_locale_remove(tag='ko')
  "add polling service etag-poller, 30s interval, tool=fetch_etag"
       → service_set(name='etag-poller', kind='polling',
                     interval=30, tool='fetch_etag', autoStart=true)
                                       (service entry under /ui/
                                       services/<name>; pass any
                                       subset of fields to merge,
                                       or `entry` to fully replace)
  "delete the etag-poller service"
       → service_remove(name='etag-poller')
  "register this template library"
       → template_library_add(uri, version?, integrity?)
                                       (idempotent on uri — appended
                                       to /ui/templateLibraries)
  "switch the theme to sepia" / "apply the warm preset"
       → theme_preset_set(preset='warm'|'cool'|'sepia'|'mono'|
                                'highContrast')
                                       (1.3.4 Phase 5 — base layer;
                                       other theme.* fields override
                                       on top)
  "register Inter font with wght axis 100~900"
       → theme_font_set(family='Inter',
                        weights={'400':'bundle://inter-regular', …},
                        variableAxes=[{tag:'wght', min:100, max:900,
                                       default:400}],
                        fallbacks=['Roboto', 'sans-serif'])
                                       (per-family entry under
                                       /ui/theme/fonts/<family>)
  "set drawer background to #112233" / "tabs indicator color"
       → navigation_style_set(slot='backgroundColor', value='#112233')
       → navigation_style_set(slot='indicatorColor', value='#FFCC00')
       → navigation_style_set(slot='iconStyle.color', value='#fff')
                                       (NavigationStyle slots under
                                       /ui/navigation/style; pass
                                       `style` map to fully replace)
  "give just the second nav item a different color" / "nav item 0 background"
       → navigation_item_style_set(index=1, slot='selectedColor',
                                   value='#FFCC00')
                                       (per-item override at
                                       /ui/navigation/items/<i>/style;
                                       layered on top of surface
                                       NavigationConfig.style)
  "set ko-KR home.title to 'Home'" / "add an i18n key"
       → i18n_text_set(locale='ko-KR', key='home.title', value='Home')
                                       (single string upsert at
                                       /ui/i18n/text/<locale>/<key>;
                                       slashes in key are escaped)
  "define plural forms for items count" / "register plurals"
       → i18n_pluralization_set(locale='en', key='items.count',
                                forms={'one':'1 item',
                                       'other':'{{count}} items'})
                                       (CLDR categories — zero / one /
                                       two / few / many / other)
  "ar-SA is RTL"
       → i18n_text_direction_set(locale='ar-SA', direction='rtl')
  "extract all strings on this page to i18n keys" / "extract strings on home"
       → extract_i18n(pageId='home', locale?, dryRun?)
                                       (literal text + button label →
                                       /ui/i18n/text/<locale>/<key>;
                                       widget rewritten to
                                       `{{i18n.text.<key>}}`. Bindings
                                       are skipped; identical strings
                                       collapse to one key.)
  "migrate old project" / "clean up assets"
       → asset_audit() / asset_audit(apply=true)
                                       (finds invalid contentRef,
                                       drops orphan registry entries,
                                       rewrites widget bundle://<id>
                                       refs to resolved bare names.)
  "where is the primary color used?" / "find every use of theme.color.X"
       → token_usage(role='primary', domain?='color')
                                       (returns definition + full
                                       usage list with widgetPath +
                                       property; pair with
                                       set_property on /ui/theme/
                                       <domain>/<role> for safe swap)
  "show me the diff before changing this widget" / "preview before applying"
       → widget_diff(path, candidate, apply?)
                                       (returns RFC 6902 ops +
                                       summary {pointer, kind} per
                                       change. Pass apply=true to
                                       commit. Use to preview a
                                       proposed swap or template
                                       expansion in chat.)
  "swap this button to an iconButton" / "swap widget type"
       → swap_widget(path, newType, dryRun?)
                                       (transfers properties whose
                                       names are present in the
                                       target schema; reports kept +
                                       dropped so author can rescue
                                       lost data via add_child or
                                       set_property afterwards)
  "design check / review" / "design critique" / "what do you think?"
       → vibe_design_critique(focus?) — returns inline image + a
         critique brief. Look at the rendered preview yourself,
         then return the JSON shape the brief specifies. Pair
         with a11y_audit / token_usage / find_widgets when a
         finding needs structural confirmation. Focus values:
         all | layout | typography | color | spacing | motion |
         a11y | consistency.
  "accessibility check" / "a11y check" / "screen-reader friendly?"
       → a11y_audit(pageId?) — list of {path, type, severity, rule,
                                        message}.
  "auto-fix a11y" / "fix the easy ones" / "bump small fontSize to 12"
       → a11y_quick_fix(pageId?, dryRun?)
                                       (auto-fixes minFontSize → 12,
                                       touchTarget < 48 → 48 width/
                                       height. Skips ambiguous
                                       missing-label failures —
                                       author still provides actual
                                       label content.)
                                       (WCAG 2.1 AA + Material —
                                       button accessible names,
                                       icon/image semanticLabel,
                                       input labels, text size ≥12,
                                       touch target ≥48.)

Pull on demand instead of carrying everything in this prompt:
  spec_card(topic) — focused 1.3.4 reference card. Topics:
    phase1_decoration · phase2_gallery · phase3_motion ·
    phase4_media · phase5_theme_nav · primitives · m3_motion
  widget_describe(type) — full schema of one widget type.
  schema_get(kind, id?) — full app/page/theme schema or a section.
  Use these the moment you need shape detail beyond the routing
  guidance below; do not guess prop names.

Each of these is ONE tool call. Do not chain `tree_outline` +
`get_widget` + `get_section` for the same answer — pick the
narrowest tool that returns what the user actually asked.

Mutation (any node — widget, theme token, page, template, …):
  set_property(path, key, value)  — UPSERT ONE field. `key` is
                                    dot-pathed inside `path`. Creates
                                    new keys; replaces existing.
                                    Examples:
                                      widget color: path=
                                        `/ui/pages/home/content/
                                        children/0`, key=`style.color`
                                      theme token: path=`/ui/theme/
                                        color`, key=`primary`
                                      app title: path=`/ui`,
                                        key=`title`
                                      new page: path=`/ui/pages`,
                                        key=`about`, value=`{type:
                                        "page", ...}`
                                    Pipeline-validated — rejects bad
                                    paths/values with a clear reason.
  add_child(parentPath, widget,   — insert under a parent. Default
            slot?, index?)         slot=`children`; pass `child` for
                                    single-child containers.
  move_widget(path, newParentPath, — atomic remove + add.
              slot?, index?)
  delete_widget(path)             — remove ANY node (widget, page,
                                    template, theme token, app
                                    field). Despite the name it is
                                    not widget-specific.
  replace_subtree(path, widget)   — wholesale replace. Use only for
                                    structural rewrites; prefer
                                    set_property for single fields.

  WHY: raw JSON read+write (read_file → write_file) burns tokens AND
  routinely produces spec violations (color in wrong slot, non-spec
  widget types like `column`/`elevatedButton`, broken JSON syntax).
  The semantic tools never let you produce structurally invalid
  patches — the validator catches mistakes before they land.

  Standard flow for "change a widget" requests:
    1. tree_outline()              — locate the path
    2. get_widget(path)            — confirm current state (optional)
    3. set_property / add_child /  — one focused op
       delete_widget / …
    4. layout_snapshot()           — verify the change rendered
                                     (skip when the change is text-
                                     only and you trust the patch)

  Standard flow for "change theme / app / templates / manifest":
    1. bundle_outline()            — see what sections + pages +
                                     templates exist
    2. get_section(section, id?)   — read the relevant section
    3. set_property / delete_widget — apply the change
    Theme tokens come back through `get_section('theme')` — that is
    the canonical entry point for the full token tree.

  Use `apply_patch` (RFC 6902 ops) ONLY when no semantic tool fits —
  e.g. cross-tree moves, theme batch changes, or operations on
  non-widget structures. For single property changes ALWAYS prefer
  set_property.

Path conventions (RFC 6901 JSON Pointer):
  /ui                           - app + theme + pages tree
  /ui/pages/<id>                - one page object
  /ui/pages/<id>/content        - the page's root widget
  /ui/templates/<id>            - component template
  /ui/dashboard                 - dashboard view
  /ui/theme                     - theme tokens

Use canonical mcp_ui DSL 1.3 names (no legacy aliases). For old
batch flows: one `apply_patch` call may batch multiple ops, but
split logically distinct changes across calls so each one is easy
to undo. Always include a short `summary`.

Reading bundle content:
  Prefer `tree_outline` for "what widgets are here?" and `get_widget`
  for "show me this widget" — both resolve through vibe's canonical,
  which sees unsaved draft edits. Raw `read_file` on bundle JSON
  paths returns committed bytes only, so use the canonical-aware
  tools for live content.

  The selection context surfaces a `contentHash = <12-char>` for the
  focused page or component. Treat it as a cache key — if the hash
  is identical to the one you saw in the previous turn AND the user
  did not request an edit since, do NOT re-fetch the tree. Reuse
  what you already know. Re-read only when the hash changes, the
  user asks about a different layer / id, or the conversation
  introduces ambiguity that requires fresh content.

Project layout (sandbox of file / build tools):
  project.apbproj             metadata file at the project root
  bundles/<channel>.mbd/      mcp_ui bundle per channel (mutate via
                              apply_patch, never write_file)
  src/                        your authored helpers, handlers,
                              custom server/app glue
  assets/                     fonts, images, shared static files
  build/<target>/             generated deployables (server, app,
                              archives) — write here for any
                              codegen output

When the user asks to build, generate, run, or test something
outside the canonical bundle, use the file + build tools:

  pack_bundle(channel, outPath)   — channel.mbd/ → outPath.mcpb
  write_file / edit_file / read_file / list_dir / delete_file
  run_shell(command, args, cwd)   — dart pub get / compile / run …
  read_build_guide()              — canonical Dart MCP server
                                    pattern (call before generating
                                    server source)
  project_info()                  — channel registry + paths
  preview_capture(pixelRatio?, outPath?) — PNG screenshot of the
                                    preview. Expensive (image bytes
                                    in the multimodal channel).
  layout_snapshot()               — rect / font / box / padding for
                                    every widget. Cheap (tiny JSON).

  Picking ONE — never both in the same turn:
    - Default: `layout_snapshot`. Covers ~90% of "did the patch
      land?" / "what size is X?" / "what color resolved?" questions.
    - `preview_capture` only when the user's wording is explicitly
      pixel-shaped ("the shadow looks off", "the button shape is
      weird", "show me the picture") OR when layout_snapshot returned
      data but you still can't tell what looks wrong. Justify the
      call in your reply.
    - If you already have a recent layout_snapshot in this turn, do
      NOT also capture a screenshot to "double-check" — that wastes
      tokens. Trust the snapshot or ask the user what looks off.

Typical build flow:
  1. project_info() to confirm paths.
  2. read_build_guide() if generating a server / app.
  3. write_file / edit_file the source under build/<target>/.
  4. pack_bundle if a .mcpb is needed.
  5. run_shell to validate (pub get, compile, stdio handshake).

When the user says "build" / "make the app" / "ship it":
  1. Call `get_build_config` first to read the saved preset (target /
     channel / outDir / runFlutterCreate). Empty payload = no preset.
  2. If a preset is saved, immediately call `run_build` with NO args
     — the preset supplies everything. Do NOT re-ask the user which
     target / channel / outDir; the preset is the canonical answer
     the user already saved via the GUI Build dialog.
  3. `run_build` auto-saves the canonical first (same as the GUI
     Build button), so any `apply_patch` from this session lands in
     the artifact without a manual save step.
  4. Only ask when no preset is saved (the tool returns empty
     payload) OR when the user's wording explicitly overrides one
     slot ("build it with the native channel" → pass `channel: 'native'`).
  5. `run_build` returns `target / channel / outDir / writtenFiles /
     sizeBytes`. Reply with a short summary ("✓ built bundle to
     <outDir>, N artifacts, X KB") — the artifact paths are useful
     for the user's next step.

Stay concise. When you don't know, say so.
''';
