/// The contract every built-in tool keeps with its caller, enforced at
/// registration instead of in each handler:
///
///   * Arguments are checked against the tool's own `inputSchema` before the
///     handler runs — a missing required field, a wrong JSON type, or a
///     top-level value outside an `enum` is answered with `invalidArguments`
///     naming each field, never with a cast error from inside the handler.
///   * A handler that throws answers `toolFailed` with the error text; the
///     caller (an external LLM or an agent loop) gets a result, not an
///     exception.
///   * A result whose JSON body reports failure — `ok: false`, or an `error`
///     message without `ok: true` — is flagged `isError`, so the failure is
///     visible to callers that only read the flag.
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:logging/logging.dart';

final Logger _log = Logger('ToolCallGuard');

typedef GuardedToolHandler =
    Future<mk.KernelToolResult> Function(Map<String, dynamic> args);

/// Problems with [args] against [schema] — one entry per offending field.
/// Checks shape — `required` and each declared property's `type` — down
/// through array `items` and nested object `properties` (a field path such
/// as `line[0].approverId` names the offender). A top-level `enum` is
/// checked only when [enforceEnums]: nested enums and the host capability
/// tools' enums are advisory, because enforcing them refused calls the
/// tools had always accepted (`formats: ['png']`). Undeclared properties
/// pass through untouched.
List<Map<String, Object?>> checkToolArgs(
  Map<String, dynamic> schema,
  Map<String, dynamic> args, {
  bool enforceEnums = true,
}) {
  final problems = <Map<String, Object?>>[];
  _checkObject(schema, args, '', problems, enforceEnums: enforceEnums);
  return problems;
}

void _checkObject(
  Map<dynamic, dynamic> schema,
  Map<dynamic, dynamic> value,
  String prefix,
  List<Map<String, Object?>> problems, {
  bool enforceEnums = false,
}) {
  final required = schema['required'];
  if (required is List) {
    for (final field in required) {
      if (value[field] == null) {
        problems.add(<String, Object?>{
          'field': '$prefix$field',
          'problem': 'missing',
        });
      }
    }
  }
  final props = schema['properties'];
  if (props is! Map) return;
  for (final entry in props.entries) {
    final spec = entry.value;
    final v = value[entry.key];
    if (v == null || spec is! Map) continue;
    _checkValue(
      spec,
      v,
      '$prefix${entry.key}',
      problems,
      enforceEnum: enforceEnums,
    );
  }
}

void _checkValue(
  Map<dynamic, dynamic> spec,
  Object value,
  String field,
  List<Map<String, Object?>> problems, {
  bool enforceEnum = false,
}) {
  final types = switch (spec['type']) {
    final String t => <String>[t],
    final List<dynamic> ts => ts.map((t) => '$t').toList(),
    _ => const <String>[],
  };
  if (types.isNotEmpty && !types.any((t) => _isJsonType(value, t))) {
    problems.add(<String, Object?>{
      'field': field,
      'problem': 'type',
      'expected': types.length == 1 ? types.first : types,
      'actual': _jsonTypeOf(value),
    });
    return;
  }
  final allowed = spec['enum'];
  if (enforceEnum && allowed is List && !allowed.contains(value)) {
    problems.add(<String, Object?>{
      'field': field,
      'problem': 'enum',
      'expected': allowed,
      'actual': value,
    });
    return;
  }
  final items = spec['items'];
  if (value is List && items is Map) {
    for (var i = 0; i < value.length; i++) {
      final item = value[i];
      if (item == null) continue;
      _checkValue(items, item as Object, '$field[$i]', problems);
    }
  }
  if (value is Map) _checkObject(spec, value, '$field.', problems);
}

bool _isJsonType(Object value, String type) => switch (type) {
  'string' => value is String,
  'boolean' => value is bool,
  'number' => value is num,
  'integer' => value is int || (value is double && value == value.truncate()),
  'object' => value is Map,
  'array' => value is List,
  'null' => false,
  // Unknown type keywords are not ours to reject.
  _ => true,
};

String _jsonTypeOf(Object value) => switch (value) {
  String() => 'string',
  bool() => 'boolean',
  int() => 'integer',
  num() => 'number',
  Map() => 'object',
  List() => 'array',
  _ => value.runtimeType.toString(),
};

mk.KernelToolResult _error(Map<String, Object?> body) => mk.KernelToolResult(
  content: <mk.KernelContent>[mk.KernelTextContent(text: jsonEncode(body))],
  isError: true,
);

/// Wrap [handler] so tool [name] keeps the contract described above.
GuardedToolHandler guardToolHandler(
  String name,
  Map<String, dynamic> schema,
  GuardedToolHandler handler, {
  bool enforceEnums = true,
}) {
  return (args) async {
    final problems = checkToolArgs(schema, args, enforceEnums: enforceEnums);
    if (problems.isNotEmpty) {
      return _error(<String, Object?>{
        'ok': false,
        'code': 'invalidArguments',
        'tool': name,
        'errors': problems,
      });
    }
    final mk.KernelToolResult result;
    try {
      result = await handler(args);
    } catch (e, st) {
      _log.warning('tool $name threw', e, st);
      return _error(<String, Object?>{
        'ok': false,
        'code': 'toolFailed',
        'tool': name,
        'error': '$e',
      });
    }
    if (result.isError == true || !_saysNotOk(result)) return result;
    return mk.KernelToolResult(content: result.content, isError: true);
  };
}

bool _saysNotOk(mk.KernelToolResult result) {
  if (result.content.isEmpty) return false;
  final first = result.content.first;
  if (first is! mk.KernelTextContent) return false;
  final text = first.text;
  if (!text.startsWith('{')) return false;
  try {
    final body = jsonDecode(text);
    if (body is! Map) return false;
    if (body['ok'] == false) return true;
    final error = body['error'];
    return error is String && error.isNotEmpty && body['ok'] != true;
  } on FormatException {
    return false;
  }
}

/// Flag a result whose JSON body reports failure (`ok: false`, or an `error`
/// without `ok: true`) as `isError`, leaving everything else as it is.
///
/// The part of [guardToolHandler] that applies to the host's own
/// `studio.*` tools: they answered failures in the body only, so MCP
/// callers that read the flag saw success. Argument checking is not applied
/// here — those tools predate the schema contract and some accept loosely
/// typed input on purpose.
GuardedToolHandler flagFailedResults(GuardedToolHandler handler) {
  return (args) async {
    final result = await handler(args);
    if (result.isError == true || !_saysNotOk(result)) return result;
    return mk.KernelToolResult(content: result.content, isError: true);
  };
}

/// A [mk.KernelServerHost] that registers every tool through
/// [flagFailedResults] and forwards everything else to [inner].
///
/// With [checkArguments] every tool gets the [guardToolHandler] contract
/// instead — used as the endpoint of the host capability registry
/// (`form.*` · `io.*` · `fs.*` · …), whose tools declare their schema like
/// the built-ins do but were registered outside [BuiltinToolRegistry]. Their
/// enums are not enforced: the capabilities accept values beyond them
/// (`form.render {format: 'png'}`).
class FailureFlaggingServerHost implements mk.KernelServerHost {
  FailureFlaggingServerHost(this.inner, {this.checkArguments = false});

  final mk.KernelServerHost inner;
  final bool checkArguments;

  @override
  void addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required mk.KernelToolHandler handler,
    mk.ToolScope scope = mk.ToolScope.external,
  }) => inner.addTool(
    name: name,
    description: description,
    inputSchema: inputSchema,
    handler:
        checkArguments
            ? guardToolHandler(name, inputSchema, handler, enforceEnums: false)
            : flagFailedResults(handler),
    scope: scope,
  );

  @override
  String get name => inner.name;
  @override
  String get version => inner.version;
  @override
  Set<mk.ToolScope> get activeVisibility => inner.activeVisibility;
  @override
  bool get debugMode => inner.debugMode;
  @override
  bool removeTool(String name) => inner.removeTool(name);
  @override
  void addResource({
    required String uri,
    required String name,
    required String description,
    required String mimeType,
    required mk.KernelResourceHandler handler,
  }) => inner.addResource(
    uri: uri,
    name: name,
    description: description,
    mimeType: mimeType,
    handler: handler,
  );
  @override
  bool removeResource(String uri) => inner.removeResource(uri);
  @override
  List<String> get resourceUris => inner.resourceUris;
  @override
  void addPrompt({
    required String name,
    required String description,
    required List<mk.KernelPromptArgument> arguments,
    required mk.KernelPromptHandler handler,
  }) => inner.addPrompt(
    name: name,
    description: description,
    arguments: arguments,
    handler: handler,
  );
  @override
  bool removePrompt(String name) => inner.removePrompt(name);
  @override
  List<mk.KernelPromptDef> get promptDefinitions => inner.promptDefinitions;
  @override
  Map<String, mk.ToolScope> get toolScopes => inner.toolScopes;
  @override
  List<mk.KernelToolDef> get toolDefinitions => inner.toolDefinitions;
  @override
  Future<mk.KernelToolResult> callTool(
    String name,
    Map<String, dynamic> args,
  ) => inner.callTool(name, args);
  @override
  Future<void> start(
    mk.KernelTransportKind transport, {
    String host = '127.0.0.1',
    int port = 7820,
  }) => inner.start(transport, host: host, port: port);
  @override
  void register() => inner.register();
  @override
  Future<void> shutdown() => inner.shutdown();
  @override
  List<Map<String, Object?>> get dispatchLog => inner.dispatchLog;
  @override
  mk.McpServerSpec? get externalSpec => inner.externalSpec;
}
