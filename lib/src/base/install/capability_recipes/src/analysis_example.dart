/// Example — `mcp_analysis` as capability tools.
///
/// Shape B: `mcp_analysis` exposes the `AnalysisPort` contract
/// (`AnalysisPortAdapter` over a spec/execution/artifact engine stack).
/// This example wraps the port's operations as `analysis.*` verbs. The
/// host injects a configured `AnalysisPort` (the heavy engine wiring is
/// host-side); the example types against the `AnalysisPort` interface, so
/// it needs no `mcp_analysis` dependency.
library;

import 'package:brain_kernel/brain_kernel.dart';

import 'capability_tool_pack.dart';

/// Capability id (namespace) — exposed names are `analysis.list_specs`, ….
const String analysisCapabilityId = 'analysis';

/// Build the analysis capability's tool list over a configured
/// [AnalysisPort].
List<CapabilityTool> analysisCapabilityTools(AnalysisPort port) {
  String requireString(Map<String, dynamic> args, String field) {
    final v = args[field];
    if (v is! String || v.isEmpty) {
      throw CapabilityToolError(
        code: 'analysis.bad_input',
        message: '$field (non-empty string) is required',
      );
    }
    return v;
  }

  return <CapabilityTool>[
    CapabilityTool(
      verb: 'list_specs',
      description: 'List available analysis specs (search / paginate).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'search': <String, dynamic>{'type': 'string'},
          'limit': <String, dynamic>{'type': 'integer'},
          'offset': <String, dynamic>{'type': 'integer'},
        },
      },
      invoke: (args) async {
        final specs = await port.listSpecs(
          search: args['search'] as String?,
          limit: args['limit'] as int?,
          offset: args['offset'] as int?,
        );
        return <String, dynamic>{
          'specs': <String>[for (final s in specs) s.specId],
        };
      },
    ),
    CapabilityTool(
      verb: 'run',
      description: 'Run an analysis by spec id with parameters.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'specId': <String, dynamic>{'type': 'string'},
          'parameters': <String, dynamic>{'type': 'object'},
        },
        'required': <String>['specId'],
      },
      invoke: (args) async {
        final params = args['parameters'];
        final job = await port.runAnalysis(
          specId: requireString(args, 'specId'),
          parameters:
              params is Map
                  ? params.cast<String, dynamic>()
                  : <String, dynamic>{},
        );
        return <String, dynamic>{'jobId': job.jobId, 'status': job.status.name};
      },
    ),
    CapabilityTool(
      verb: 'get_job',
      description: 'Status/progress of an analysis job by id.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'jobId': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['jobId'],
      },
      invoke: (args) async {
        final job = await port.getJob(requireString(args, 'jobId'));
        return <String, dynamic>{
          'found': job != null,
          if (job != null) 'status': job.status.name,
        };
      },
    ),
  ];
}
