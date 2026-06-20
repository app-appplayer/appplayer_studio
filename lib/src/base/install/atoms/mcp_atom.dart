/// Cross-tool dispatch atom — `host.mcp.*`. Lets a JS tool invoke
/// any other MCP tool registered on the host's server, including:
///
///   * Built-in studio tools (`studio.*`)
///   * Other bundles' tools (`<otherBundle>.<verb>`)
///   * Its own bundle's other tools (cross-tool composition)
///
/// The bundle must list `'mcp'` in `requires.builtinAtoms` to gain
/// access. Per-tool authorisation (which target tools are callable)
/// is the host's call to make in a follow-up; this atom currently
/// allows any registered tool.
library;

import 'dart:convert';

import '../../session/session.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'atom_category.dart';

class McpAtom extends AtomCategory {
  McpAtom({required this.boot, this.sessionBridge, this.sessionResolver});

  final mk.KernelServerHost boot;

  /// Optional host bridge. When present (and [sessionResolver]
  /// yields a non-null session), every `callTool` from JS runs
  /// inside that session's Zone so the host tool handler's
  /// `scopeId` sees the right bundleId. Without this wiring the
  /// JS call would fall back to the foreground singleton and
  /// background dispatchers from non-foreground bundles would
  /// pick up the wrong caller.
  final BundleSessionBridge? sessionBridge;
  final DispatchSession? Function()? sessionResolver;

  @override
  String get key => 'mcp';

  @override
  List<AtomVerb> get verbs => const [
    AtomVerb(
      'callTool',
      description:
          'Invoke a registered host MCP tool. (toolName, args) → '
          '{isError, body}.',
    ),
    AtomVerb('listTools', description: 'List registered host MCP tool ids.'),
  ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    switch (verb) {
      case 'callTool':
        if (args.isEmpty) {
          throw ArgumentError('callTool requires (toolName, [args])');
        }
        final toolName = args[0];
        if (toolName is! String || toolName.isEmpty) {
          throw ArgumentError('toolName must be a non-empty String');
        }
        final toolArgs = args.length > 1 ? args[1] : const <String, dynamic>{};
        if (toolArgs is! Map) {
          throw ArgumentError('args must be an object map');
        }
        final argsMap = Map<String, dynamic>.from(toolArgs);
        final session = sessionResolver?.call();
        final bridge = sessionBridge;
        Future<mk.KernelToolResult> doCall() =>
            boot.callTool(toolName, argsMap);
        final mk.KernelToolResult result;
        if (bridge != null && session != null) {
          result = await bridge.runScoped(session, doCall);
        } else {
          // No session wired — fall back to whatever the current
          // DispatchContext zone says. Foreground tab path stays
          // valid; background path is on its own.
          result = await DispatchContext.instance.runScoped(
            session ??
                DispatchSession(
                  sessionId: 'mcp_atom_anon',
                  bundleId: 'host',
                  master: true,
                ),
            doCall,
          );
        }
        return _resultToJsonValue(result);
      case 'listTools':
        return boot.toolScopes.keys.toList();
      default:
        throw ArgumentError('unknown verb: mcp.$verb');
    }
  }

  /// Bridge `CallToolResult` to a plain JSON value for the JS caller.
  /// Single-text-content responses (the common case) are returned as
  /// `{isError, body}` where `body` is the JSON-decoded text when it
  /// parses, or the raw text otherwise. Multi-content / non-text
  /// responses are returned verbatim through the kernel's JSON shape.
  Map<String, dynamic> _resultToJsonValue(mk.KernelToolResult result) {
    if (result.content.length == 1 &&
        result.content.first is mk.KernelTextContent) {
      final text = (result.content.first as mk.KernelTextContent).text;
      Object? body = text;
      // Only attempt JSON decode when the body looks like JSON — plain
      // prose tools just get the string passed through.
      final trimmed = text.trim();
      if (trimmed.isNotEmpty) {
        final c = trimmed.codeUnitAt(0);
        final looksLikeJson =
            c == 0x7B /*{*/ ||
            c == 0x5B /*[*/ ||
            c == 0x22 /*"*/ ||
            (c >= 0x30 && c <= 0x39) ||
            trimmed == 'null' ||
            trimmed == 'true' ||
            trimmed == 'false';
        if (looksLikeJson) {
          try {
            body = jsonDecode(trimmed);
          } catch (_) {
            // Fall through to raw text.
          }
        }
      }
      return <String, dynamic>{'isError': result.isError, 'body': body};
    }
    return <String, dynamic>{
      'isError': result.isError,
      'content': <Map<String, dynamic>>[
        for (final c in result.content)
          if (c is mk.KernelTextContent)
            <String, dynamic>{'type': 'text', 'text': c.text}
          else
            <String, dynamic>{'type': c.runtimeType.toString()},
      ],
    };
  }
}
