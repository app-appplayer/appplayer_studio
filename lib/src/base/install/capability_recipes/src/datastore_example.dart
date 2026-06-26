/// Example — `mcp_datastore` as capability tools.
///
/// Shape A: `mcp_datastore`'s `DatastoreTools` already exposes a ready tool
/// surface — `tools` (name / description / inputSchema) plus
/// `call(name, args)`. The surface spans two namespaces (`fs.*` / `db.*`);
/// since `registerCapabilityTools` adds the `<capabilityId>.` prefix, this
/// example splits them into **two capability ids** — `fs` and `db` — and maps
/// each tool's bare verb. The host injects a configured `DatastoreTools`
/// (a `DatasourceRegistry` of sources + a `DatastorePolicy`) and embeds
/// whichever namespaces it wants.
library;

import 'package:mcp_datastore/mcp_datastore.dart';

import 'capability_tool_pack.dart';

/// Capability ids — exposed names are `fs.read`, `db.query`, ….
const String fsCapabilityId = 'fs';
const String dbCapabilityId = 'db';

/// `fs.*` tools from a configured [DatastoreTools].
List<CapabilityTool> fsCapabilityTools(DatastoreTools datastore) =>
    _namespaceTools(datastore, 'fs');

/// `db.*` tools from a configured [DatastoreTools] (empty until a db source
/// is registered).
List<CapabilityTool> dbCapabilityTools(DatastoreTools datastore) =>
    _namespaceTools(datastore, 'db');

List<CapabilityTool> _namespaceTools(DatastoreTools datastore, String ns) {
  final prefix = '$ns.';
  return <CapabilityTool>[
    for (final t in datastore.tools.where((t) => t.name.startsWith(prefix)))
      CapabilityTool(
        // Drop the `fs.`/`db.` prefix — capabilityId re-adds it.
        verb: t.name.substring(prefix.length),
        description: t.description ?? '',
        inputSchema: t.inputSchema ?? const <String, dynamic>{'type': 'object'},
        invoke: (args) async {
          final result = await datastore.call(t.name, args);
          if (result.isError) {
            throw CapabilityToolError(
              code: result.errorCode ?? 'datastore.error',
              message: result.errorMessage ?? 'datastore operation failed',
            );
          }
          return result.value;
        },
      ),
  ];
}
