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
/// The verbs cover every operation on the port; a port operation without a
/// verb is unreachable from a bundle.
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

  final tools = <CapabilityTool>[
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
    CapabilityTool(
      verb: 'list_jobs',
      description:
          'List analysis jobs, most recent first (filter by spec / status).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'specId': <String, dynamic>{'type': 'string'},
          'status': <String, dynamic>{
            'type': 'string',
            'enum': <String>[
              'queued',
              'running',
              'completed',
              'failed',
              'canceled',
            ],
          },
          'limit': <String, dynamic>{'type': 'integer'},
        },
      },
      invoke: (args) async {
        final rawStatus = args['status'];
        AnalysisJobStatus? status;
        if (rawStatus != null) {
          // An unknown status must not fall back to a default filter.
          status =
              AnalysisJobStatus.values
                  .where((e) => e.name == rawStatus)
                  .firstOrNull;
          if (status == null) {
            throw CapabilityToolError(
              code: 'analysis.bad_input',
              message:
                  'status must be one of '
                  '${AnalysisJobStatus.values.map((e) => e.name).join(', ')}',
            );
          }
        }
        final jobs = await port.listJobs(
          specId: args['specId'] as String?,
          status: status,
          limit: args['limit'] as int?,
        );
        return <String, dynamic>{
          'jobs': <Map<String, dynamic>>[
            for (final j in jobs)
              <String, dynamic>{
                'jobId': j.jobId,
                'specId': j.specId,
                'status': j.status.name,
              },
          ],
        };
      },
    ),
    CapabilityTool(
      verb: 'cancel_job',
      description: 'Cancel a queued or running analysis job by id.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'jobId': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['jobId'],
      },
      invoke: (args) async {
        final job = await port.cancelJob(requireString(args, 'jobId'));
        return <String, dynamic>{'jobId': job.jobId, 'status': job.status.name};
      },
    ),
    CapabilityTool(
      verb: 'get_artifacts',
      description:
          'Fetch result artifacts (metric/series/table/…) by job or spec.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'jobId': <String, dynamic>{'type': 'string'},
          'specId': <String, dynamic>{'type': 'string'},
          'limit': <String, dynamic>{'type': 'integer'},
        },
      },
      invoke: (args) async {
        final artifacts = await port.getArtifacts(
          jobId: args['jobId'] as String?,
          specId: args['specId'] as String?,
          limit: args['limit'] as int?,
        );
        return <String, dynamic>{
          'artifacts': <Map<String, dynamic>>[
            for (final a in artifacts) a.toJson(),
          ],
        };
      },
    ),
    CapabilityTool(
      verb: 'create_spec',
      description: 'Register an analysis spec (AnalysisSpec JSON).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'spec': <String, dynamic>{'type': 'object'},
        },
        'required': <String>['spec'],
      },
      invoke: (args) async {
        final raw = args['spec'];
        if (raw is! Map) {
          throw CapabilityToolError(
            code: 'analysis.bad_input',
            message: 'spec (AnalysisSpec JSON object) is required',
          );
        }
        final created = await port.createSpec(
          AnalysisSpec.fromJson(raw.cast<String, dynamic>()),
        );
        return <String, dynamic>{
          'specId': created.specId,
          'version': created.version,
        };
      },
    ),
    CapabilityTool(
      verb: 'update_spec',
      description: 'Update an existing analysis spec by id.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'specId': <String, dynamic>{'type': 'string'},
          'spec': <String, dynamic>{'type': 'object'},
        },
        'required': <String>['specId', 'spec'],
      },
      invoke: (args) async {
        final raw = args['spec'];
        if (raw is! Map) {
          throw CapabilityToolError(
            code: 'analysis.bad_input',
            message: 'spec (AnalysisSpec JSON object) is required',
          );
        }
        final updated = await port.updateSpec(
          requireString(args, 'specId'),
          AnalysisSpec.fromJson(raw.cast<String, dynamic>()),
        );
        return <String, dynamic>{
          'specId': updated.specId,
          'version': updated.version,
        };
      },
    ),
    CapabilityTool(
      verb: 'delete_spec',
      description: 'Delete an analysis spec by id.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'specId': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['specId'],
      },
      invoke: (args) async {
        final specId = requireString(args, 'specId');
        await port.deleteSpec(specId);
        return <String, dynamic>{'specId': specId, 'deleted': true};
      },
    ),
    CapabilityTool(
      verb: 'list_functions',
      description:
          'Describe the analysis functions a spec may call: parameters and '
          'result fields (search by name).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'search': <String, dynamic>{'type': 'string'},
        },
      },
      invoke: (args) async {
        final functions = await port.listFunctions(
          search: args['search'] as String?,
        );
        return <String, dynamic>{
          'functions': <Map<String, dynamic>>[
            for (final f in functions) f.toJson(),
          ],
        };
      },
    ),
    CapabilityTool(
      verb: 'evaluate_alert',
      description: 'Evaluate an alert rule by id.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'alertRuleId': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['alertRuleId'],
      },
      invoke: (args) async {
        final alert = await port.evaluateAlert(
          requireString(args, 'alertRuleId'),
        );
        return alert.toJson();
      },
    ),
  ];
  return <CapabilityTool>[for (final t in tools) _withPortErrors(t)];
}

/// A port refusal reaches the caller with its code and, for a rejected
/// spec, the per-issue codes. Without this the pack's generic catch reports
/// `capability.error` with the top-level message only, and the caller
/// cannot tell which rule the spec broke.
CapabilityTool _withPortErrors(CapabilityTool tool) => CapabilityTool(
  verb: tool.verb,
  description: tool.description,
  inputSchema: tool.inputSchema,
  invoke: (args) async {
    try {
      return await tool.invoke(args);
    } on AnalysisError catch (e) {
      final issues = e.details?['issues'];
      final detail =
          issues is List && issues.isNotEmpty
              ? ': ${issues.map((i) => i is Map ? '${i['code']} (${i['field']})' : '$i').join('; ')}'
              : '';
      throw CapabilityToolError(
        code: 'analysis.${e.code}',
        message: '${e.message}$detail',
      );
    }
  },
);
