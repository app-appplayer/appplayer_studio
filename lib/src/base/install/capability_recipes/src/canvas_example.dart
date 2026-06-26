/// Example — `mcp_canvas` (CDL 2D/3D engine) as capability tools.
///
/// Shape B: `mcp_canvas` ships a pure-Dart `Canvas` engine + CDL (Canvas
/// Definition Language). This example wraps the **stateless transforms** —
/// CDL ↔ JSON parse / serialize / validate — as `canvas.*` verbs (each
/// call uses a fresh `Canvas`). Pure Dart, no Flutter; pixel rendering is
/// a separate decoupled `CanvasRenderer`, out of scope for a tool surface.
library;

import 'package:mcp_canvas/mcp_canvas.dart';

import 'capability_tool_pack.dart';

/// Capability id (namespace) — exposed names are `canvas.cdl_to_json`, ….
const String canvasCapabilityId = 'canvas';

/// Build the canvas capability's tool list. No injected runtime — the
/// transforms are stateless (fresh `Canvas` per call).
List<CapabilityTool> canvasCapabilityTools() {
  String requireString(Map<String, dynamic> args, String field) {
    final v = args[field];
    if (v is! String || v.isEmpty) {
      throw CapabilityToolError(
        code: 'canvas.bad_input',
        message: '$field (non-empty string) is required',
      );
    }
    return v;
  }

  Canvas parseCdl(String cdl) {
    try {
      return Canvas()..fromCdl(cdl);
    } on Object catch (e) {
      throw CapabilityToolError(code: 'canvas.parse_failed', message: '$e');
    }
  }

  return <CapabilityTool>[
    CapabilityTool(
      verb: 'cdl_to_json',
      description: 'Parse a CDL document and return its canvas JSON.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'cdl': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['cdl'],
      },
      invoke: (args) async => parseCdl(requireString(args, 'cdl')).toJson(),
    ),
    CapabilityTool(
      verb: 'json_to_cdl',
      description: 'Serialize a canvas JSON document to CDL text.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'definition': <String, dynamic>{'type': 'object'},
        },
        'required': <String>['definition'],
      },
      invoke: (args) async {
        final def = args['definition'];
        if (def is! Map) {
          throw const CapabilityToolError(
            code: 'canvas.bad_input',
            message: 'definition (object) is required',
          );
        }
        try {
          final c = Canvas()..fromJson(def.cast<String, dynamic>());
          return <String, dynamic>{'cdl': c.toCdl()};
        } on CapabilityToolError {
          rethrow;
        } on Object catch (e) {
          throw CapabilityToolError(
            code: 'canvas.serialize_failed',
            message: '$e',
          );
        }
      },
    ),
    CapabilityTool(
      verb: 'validate_cdl',
      description: 'Parse a CDL document; report whether it is valid.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'cdl': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['cdl'],
      },
      invoke: (args) async {
        parseCdl(requireString(args, 'cdl'));
        return <String, dynamic>{'valid': true};
      },
    ),
  ];
}
