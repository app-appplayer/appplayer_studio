/// Tiny wrapper around [mk.KernelServerHost.toolDefinitions] every
/// studio host needs to satisfy [StudioApp.fetchAllToolDefinitions]
/// without each host re-implementing the null check + return-shape.
library;

import 'package:brain_kernel/brain_kernel.dart' as mk;

/// Return the bootstrap's `toolDefinitions` list, or an empty list when
/// the host has not yet built the server. The returned shape matches
/// MCP's `tools/list` — one map per tool with `{name, description,
/// inputSchema}` keys — so the agent host feeds it straight to the LLM.
List<Map<String, dynamic>> studioToolDefinitions(mk.KernelServerHost? boot) {
  if (boot == null) return const <Map<String, dynamic>>[];
  return <Map<String, dynamic>>[
    for (final d in boot.toolDefinitions) d.toJson(),
  ];
}
