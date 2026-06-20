/// `registerMetaTools` — register the 2 `studio.meta.*` MCP tools
/// (tool catalogue introspection) onto a kernel `ServerBootstrap`.
///
/// Lifted verbatim from `vibe_studio_host_app.dart` so every studio
/// host gets the same surface for free. Mechanical refactor — no
/// behaviour change. The handlers read `boot.toolDefinitions` directly,
/// which mirrors the host's `fetchAllToolDefinitions()` implementation.
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;

/// Register the 2 `studio.meta.*` tools onto [boot]:
///
/// - `studio.meta.list_tools` — name + description list, optional
///   prefix filter.
/// - `studio.meta.describe_tool` — full `{name, description,
///   inputSchema}` for a single tool by name.
void registerMetaTools(mk.KernelServerHost boot) {
  boot.addTool(
    name: 'studio.meta.list_tools',
    description:
        'List every MCP tool registered on this server. Pass '
        '`prefix` to filter by name prefix (e.g. `studio.debug.`). '
        'Returns `{tools: [{name, description}]}` — drop the schema '
        'so the response stays small; call `studio.meta.describe_'
        'tool` for the full definition of one tool.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'prefix': <String, dynamic>{
          'type': 'string',
          'description': 'Optional name prefix filter (e.g. `studio.chrome.`).',
        },
      },
    },
    handler: (args) async {
      final prefix = (args['prefix'] as String?) ?? '';
      final defs = boot.toolDefinitions;
      final filtered = <Map<String, dynamic>>[
        for (final d in defs)
          if (prefix.isEmpty || d.name.startsWith(prefix))
            <String, dynamic>{'name': d.name, 'description': d.description},
      ];
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{'tools': filtered}),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.meta.describe_tool',
    description:
        'Return the full definition (`{name, description, '
        'inputSchema}`) of one tool by name. Returns `{error: ...}` '
        'with `isError: true` when the name does not match any '
        'registered tool.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'name': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['name'],
    },
    handler: (args) async {
      final name = args['name'];
      if (name is! String || name.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"name required"}'),
          ],
          isError: true,
        );
      }
      final defs = boot.toolDefinitions;
      final hit = defs.where((d) => d.name == name).firstOrNull;
      if (hit == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'error': 'no tool named $name',
              }),
            ),
          ],
          isError: true,
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(hit.toJson())),
        ],
      );
    },
  );
}
