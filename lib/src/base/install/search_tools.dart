/// `registerSearchTools` — register the `studio.search.*` MCP tools
/// (BM25 zero-LLM search across installed bundles) onto a kernel
/// `ServerBootstrap`.
///
/// Lifted verbatim from `vibe_studio_host_app.dart` so every studio
/// host shares the same search surface. The handler routes through
/// [BundleInstallSurface.query] which wraps the kernel's
/// `KnowledgeQueryEngine`.
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../main/bundle_install_surface.dart';

/// Register the `studio.search.*` tools onto [boot]:
///
/// - `studio.search.query` — top-K BM25 hits across installed
///   bundles, optionally scoped by `namespace` / `sourceId`.
void registerSearchTools(
  mk.KernelServerHost boot, {
  required BundleInstallSurface bundles,
}) {
  boot.addTool(
    name: 'studio.search.query',
    description:
        'BM25 zero-LLM search across all installed bundles. Returns '
        'top-K chunk hits ranked by lexical relevance. Pass '
        '`namespace` / `sourceId` to narrow the search to a single '
        'bundle / source. Empty `text` yields an empty list.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'text': <String, dynamic>{'type': 'string'},
        'topK': <String, dynamic>{
          'type': 'integer',
          'minimum': 1,
          'description': 'Max hits returned (default 5).',
        },
        'namespace': <String, dynamic>{
          'type': 'string',
          'description':
              'Limit to a single bundle namespace (e.g. '
              '`com.makemind.examples.demo_showcase`).',
        },
        'sourceId': <String, dynamic>{
          'type': 'string',
          'description': 'Limit to a single source within the bundle.',
        },
      },
      'required': <String>['text'],
    },
    handler: (args) async {
      final text = args['text'];
      if (text is! String) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"text required"}'),
          ],
          isError: true,
        );
      }
      final topK = (args['topK'] as num?)?.toInt() ?? 5;
      final ns = args['namespace'] as String?;
      final src = args['sourceId'] as String?;
      final hits = await bundles.query(
        text,
        topK: topK,
        namespace: ns,
        sourceId: src,
      );
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{'hits': hits}),
          ),
        ],
      );
    },
  );
}
