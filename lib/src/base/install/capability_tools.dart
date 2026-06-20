/// Host-level form + ingest capabilities.
///
/// Exposes `mcp_form` (`form.*`) and `mcp_ingest` (`ingest.*`) as general
/// host tools on the shared [HostToolRegistry], so any built-in (ops, …)
/// or bundle app uses one engine instead of owning its own (parity rule).
/// Mirrors the `capability_tools` reference recipe, written directly into
/// the host to avoid a path-vs-pub version clash on mcp_form / mcp_ingest.
library;

import 'dart:convert' show jsonEncode;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:mcp_form/mcp_form.dart';
import 'package:mcp_ingest/mcp_ingest.dart';

/// Register `form.<verb>` for every tool `mcp_form` declares (shape A —
/// the package ships its own MCP tool surface).
List<String> registerFormCapability(HostToolRegistry registry) {
  final handler = _assembleFormToolHandler();
  final exposed = <String>[];
  for (final def in handler.toolDefinitions) {
    // mcp_form declares names already prefixed (`form.render`); strip so
    // the registry does not double the namespace.
    final verb = _stripPrefix(def.name, 'form.');
    exposed.add(
      registry.registerExposed(
        bundleId: 'form',
        rawName: verb,
        description: def.description,
        inputSchema: def.inputSchema,
        handler: (args) async {
          try {
            final out = await handler.handleToolCall(
              toolName: def.name,
              arguments: args,
            );
            return _result(out, isError: false);
          } on McpToolError catch (e) {
            return _result(<String, dynamic>{
              'ok': false,
              'code': e.code,
              'error': e.message,
            }, isError: true);
          } catch (e) {
            return _result(<String, dynamic>{
              'ok': false,
              'code': 'form.error',
              'error': e.toString(),
            }, isError: true);
          }
        },
      ),
    );
  }
  return exposed;
}

/// Register `ingest.run` (shape B — wrap the `IngestPipeline` runtime).
List<String> registerIngestCapability(HostToolRegistry registry) {
  final pipeline = IngestPipeline.defaults();
  return <String>[
    registry.registerExposed(
      bundleId: 'ingest',
      rawName: 'run',
      description: 'Ingest a text document into normalized chunks.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'content': <String, dynamic>{
            'type': 'string',
            'description': 'Raw document text to ingest.',
          },
          'filename': <String, dynamic>{'type': 'string'},
          'mimeType': <String, dynamic>{
            'type': 'string',
            'default': 'text/plain',
          },
        },
        'required': <String>['content'],
      },
      handler: (args) async {
        try {
          final content = args['content'];
          if (content is! String || content.isEmpty) {
            return _result(<String, dynamic>{
              'ok': false,
              'code': 'ingest.bad_input',
              'error': 'content (non-empty string) is required',
            }, isError: true);
          }
          final input = IngestInput.fromString(
            content,
            filename: args['filename'] as String?,
            mimeType: (args['mimeType'] as String?) ?? 'text/plain',
          );
          final out = await pipeline.ingest(input, IngestOptions.defaults);
          if (out.error != null) {
            return _result(<String, dynamic>{
              'ok': false,
              'code': 'ingest.failed',
              'error': out.error.toString(),
            }, isError: true);
          }
          return _result(<String, dynamic>{
            'ok': true,
            'count': out.chunks.length,
            // Return chunk texts so consumers (e.g. a knowledge ingest that
            // extracts facts) can use them — not just the count.
            'chunks': <Map<String, dynamic>>[
              for (final c in out.chunks) <String, dynamic>{'text': c.text},
            ],
            'warnings': out.warnings,
          }, isError: false);
        } catch (e) {
          return _result(<String, dynamic>{
            'ok': false,
            'code': 'ingest.error',
            'error': e.toString(),
          }, isError: true);
        }
      },
    ),
  ];
}

FormToolHandler _assembleFormToolHandler() {
  final templatePort = FormTemplatePortImpl();
  final formPort = FormPortImpl(templatePort: templatePort);
  final rendererPort = FormRendererPortImpl(
    registry: RendererRegistry(),
    templatePort: templatePort,
  );
  return FormToolHandler(
    formPort: formPort,
    templatePort: templatePort,
    rendererPort: rendererPort,
  );
}

KernelToolResult _result(Object? value, {required bool isError}) {
  return KernelToolResult(
    content: <KernelContent>[KernelTextContent(text: jsonEncode(value))],
    isError: isError,
  );
}

String _stripPrefix(String name, String prefix) =>
    name.startsWith(prefix) ? name.substring(prefix.length) : name;
