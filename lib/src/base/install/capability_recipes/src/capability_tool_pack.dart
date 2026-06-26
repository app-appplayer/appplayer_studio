/// The reference pattern — capability-agnostic.
///
/// A host embeds a capability by handing its tools to
/// [registerCapabilityTools]. Every tool lands on the host's
/// [HostToolRegistry] under `<capabilityId>.<verb>` (the general-tool
/// wiring path, never the `bk.*` knowledge surface), with a boundary
/// guard so a misbehaving capability never throws into the host
/// dispatcher. This single function is what Studio and AppPlayer both
/// call — the capability-specific code (see the form / ingest examples)
/// only produces the [CapabilityTool] list.
library;

import 'dart:convert' show jsonEncode;

import 'package:brain_kernel/brain_kernel.dart';

/// One capability tool: a bare [verb] within the capability namespace
/// (no `<capabilityId>.` prefix — the registry adds it), its schema, and
/// an [invoke] that returns a JSON-serializable value or throws.
class CapabilityTool {
  const CapabilityTool({
    required this.verb,
    required this.description,
    required this.inputSchema,
    required this.invoke,
  });

  final String verb;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Future<Object?> Function(Map<String, dynamic> args) invoke;
}

/// Structured failure a capability example raises to carry a stable
/// error code across the boundary. Plain exceptions are caught too, but
/// without a code.
class CapabilityToolError implements Exception {
  const CapabilityToolError({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => 'CapabilityToolError($code): $message';
}

/// Register every [tools] entry onto [registry] under
/// `<capabilityId>.<verb>`. Returns the exposed names. Idempotent per
/// `(capabilityId, verb)`. A host calls this once per embedded
/// capability — embedding all ecosystem capabilities or only a subset
/// (partial assembly) is just how many times this is called.
List<String> registerCapabilityTools(
  HostToolRegistry registry, {
  required String capabilityId,
  required List<CapabilityTool> tools,
}) {
  final exposed = <String>[];
  for (final tool in tools) {
    exposed.add(
      registry.registerExposed(
        bundleId: capabilityId,
        rawName: tool.verb,
        description: tool.description,
        inputSchema: tool.inputSchema,
        handler: (args) => _guard(tool.invoke, args),
      ),
    );
  }
  return exposed;
}

/// Run an [invoke] and map its result — or any failure — onto the
/// kernel tool result envelope. Mirrors the kernel's own tool
/// convention (`ops_tools` / `wrapInProcess`): no exception escapes the
/// tool boundary.
Future<KernelToolResult> _guard(
  Future<Object?> Function(Map<String, dynamic>) invoke,
  Map<String, dynamic> args,
) async {
  try {
    final result = await invoke(args);
    return KernelToolResult(
      content: <KernelContent>[KernelTextContent(text: jsonEncode(result))],
      isError: false,
    );
  } on CapabilityToolError catch (e) {
    return _error(code: e.code, message: e.message);
  } catch (e) {
    return _error(code: 'capability.error', message: e.toString());
  }
}

KernelToolResult _error({required String code, required String message}) {
  return KernelToolResult(
    content: <KernelContent>[
      KernelTextContent(
        text: jsonEncode(<String, dynamic>{
          'ok': false,
          'code': code,
          'error': message,
        }),
      ),
    ],
    isError: true,
  );
}
