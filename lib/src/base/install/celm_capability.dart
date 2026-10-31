/// Host `celm.*` capability — a guarded local loop whose eyes, hands and
/// interlock are the host's own tools. Wiring only; the loop lives in
/// `mcp_celm`.
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:mcp_celm/mcp_celm.dart';

import 'capability_recipes/capability_recipes.dart';

const String celmCapabilityId = 'celm';

/// Calls host tools as `<server>.<tool>` and reads their JSON answer.
class HostToolCaller implements McpToolCaller {
  const HostToolCaller(this.host);

  final mk.KernelServerHost host;

  @override
  Future<Map<String, dynamic>> call(
    String server,
    String tool,
    Map<String, dynamic> args,
  ) async {
    final name = '$server.$tool';
    final r = await host.callTool(name, args);
    final text =
        r.content.whereType<mk.KernelTextContent>().map((c) => c.text).join();
    if (r.isError == true) {
      throw AnalysisError(
        code: 'celm.tool_failed',
        message: '$name failed: $text',
        details: <String, dynamic>{'tool': name},
      );
    }
    if (text.isEmpty) return const <String, dynamic>{};
    final decoded = jsonDecode(text);
    return decoded is Map
        ? decoded.cast<String, dynamic>()
        : <String, dynamic>{'value': decoded};
  }
}

/// Register `celm.*` on [registry]. [host] is the tool surface the loop's
/// ports are resolved against. Returns the exposed names.
List<String> registerCelmCapability(
  mk.HostToolRegistry registry, {
  required mk.KernelServerHost host,
}) {
  final caller = HostToolCaller(host);
  CelmPort? port;

  Map<String, dynamic> map(Object? v, String where) {
    if (v is Map) return v.cast<String, dynamic>();
    throw CapabilityToolError(
      code: 'celm.bad_input',
      message: '$where (object) is required',
    );
  }

  String str(Map<String, dynamic> m, String key, String where) {
    final v = m[key];
    if (v is String && v.isNotEmpty) return v;
    throw CapabilityToolError(
      code: 'celm.bad_input',
      message: '$where.$key (non-empty string) is required',
    );
  }

  void requireTool(String server, String tool, String where) {
    final name = '$server.$tool';
    if (!host.toolDefinitions.any((d) => d.name == name)) {
      throw CapabilityToolError(
        code: 'celm.unknown_tool',
        message: '$where refers to $name, which this host does not serve',
      );
    }
  }

  Future<Object?> guarded(Future<Object?> Function() body) async {
    try {
      return await body();
    } on AnalysisError catch (e) {
      throw CapabilityToolError(code: e.code, message: e.message);
    }
  }

  final tools = <CapabilityTool>[
    CapabilityTool(
      verb: 'load',
      description:
          'Configure the local loop: manifest, surface/domain packs '
          'and the host tools that act as perception, actuators and interlock.',
      inputSchema: const {
        'type': 'object',
        'required': [
          'manifest',
          'surfacePacks',
          'domainPacks',
          'perception',
          'actuators',
        ],
        'properties': {
          'manifest': {'type': 'object'},
          'surfacePacks': {'type': 'object'},
          'domainPacks': {'type': 'object'},
          'perception': {'type': 'object'},
          'actuators': {'type': 'object'},
          'interlock': {'type': 'object'},
        },
      },
      invoke:
          (args) => guarded(() async {
            final manifest = map(args['manifest'], 'manifest');
            final surface = map(args['surfacePacks'], 'surfacePacks');
            final domain = map(args['domainPacks'], 'domainPacks');

            final p = map(args['perception'], 'perception');
            final pServer = str(p, 'server', 'perception');
            final pTool = str(p, 'tool', 'perception');
            requireTool(pServer, pTool, 'perception');
            final depths =
                (p['depths'] as List?)
                    ?.map((d) => CelmDepth.values.byName('$d'))
                    .toSet();

            final actuators = <String, CelmActuatorPort>{};
            for (final e in map(args['actuators'], 'actuators').entries) {
              final a = map(e.value, 'actuators.${e.key}');
              final server = str(a, 'server', 'actuators.${e.key}');
              final vocab = (a['vocabulary'] as List?)?.cast<String>().toSet();
              if (vocab == null || vocab.isEmpty) {
                throw CapabilityToolError(
                  code: 'celm.bad_input',
                  message:
                      'actuators.${e.key}.vocabulary (non-empty array) is required',
                );
              }
              for (final verb in vocab) {
                requireTool(server, verb, 'actuators.${e.key}');
              }
              final kinds =
                  (a['kinds'] as Map?)?.map(
                    (k, v) =>
                        MapEntry('$k', CelmActionKind.values.byName('$v')),
                  ) ??
                  const <String, CelmActionKind>{};
              actuators[e.key] = McpActuatorAdapter(
                caller: caller,
                server: server,
                vocabulary: vocab,
                kinds: kinds,
              );
            }

            CelmInterlockPort? interlock;
            if (args['interlock'] != null) {
              final i = map(args['interlock'], 'interlock');
              final iServer = str(i, 'server', 'interlock');
              final iTool = str(i, 'tool', 'interlock');
              requireTool(iServer, iTool, 'interlock');
              interlock = McpInterlockAdapter(
                caller: caller,
                server: iServer,
                tool: iTool,
              );
            }

            // Built aside and swapped in only when whole: a failed load leaves the
            // previous loop exactly as it was.
            final built = CelmPortAdapter.fromManifest(
              manifest,
              surfacePacks: {
                for (final e in surface.entries)
                  e.key: CelmSurfacePack.fromJson(
                    map(e.value, 'surfacePacks.${e.key}'),
                  ),
              },
              domainPacks: {
                for (final e in domain.entries)
                  e.key: CelmDomainPack.fromJson(
                    map(e.value, 'domainPacks.${e.key}'),
                  ),
              },
              perception:
                  depths == null
                      ? McpPerceptionAdapter(
                        caller: caller,
                        server: pServer,
                        tool: pTool,
                      )
                      : McpPerceptionAdapter(
                        caller: caller,
                        server: pServer,
                        tool: pTool,
                        depths: depths,
                      ),
              actuators: actuators,
              interlock: interlock,
            );
            port = built;
            return <String, dynamic>{'ok': true};
          }),
    ),
    for (final name in CelmToolHandler.tools)
      CapabilityTool(
        verb: name.substring('celm.'.length),
        description: _describe(name),
        inputSchema:
            CelmToolHandler.schemas[name] ??
            const <String, dynamic>{'type': 'object'},
        invoke:
            (args) => guarded(() async {
              final p = port;
              if (p == null) {
                throw const CapabilityToolError(
                  code: 'celm.not_loaded',
                  message: 'call celm.load before using the loop',
                );
              }
              return CelmToolHandler(p).call(name, args);
            }),
      ),
  ];

  return registerCapabilityTools(
    registry,
    capabilityId: celmCapabilityId,
    tools: tools,
  );
}

String _describe(String tool) => switch (tool) {
  'celm.execute' =>
    'Start a declared goal by id; returns a runId. The '
        'loop acts only through verified steps.',
  'celm.cancel' => 'Stop a running goal; evidence already established stays.',
  'celm.observe' => 'Current structured state at a scope and depth.',
  'celm.progress' =>
    'Progress, attempts and budget of a run; its outcome '
        'once it has ended.',
  'celm.explain' => 'The evidence chain behind a conclusion.',
  'celm.resume' => 'Resume an escalated run with a planner\'s answer.',
  'celm.standalone' =>
    'Conclusions of a run that may stand alone as '
        'evidence (observations only).',
  _ => tool,
};
