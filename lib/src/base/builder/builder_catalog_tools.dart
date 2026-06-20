/// Registers the two `studio.builder.ui.catalog.*` MCP tools on a
/// kernel `ServerBootstrap`. Tools are the only surface external
/// LLMs (and the in-builder manager agent) use to discover what
/// widget types and props they can author with.
///
/// `catalog.list` — flat list with optional category / source filter.
/// `catalog.schema` — full spec for one widget type (optional examples).
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'builder_catalog_service.dart';

/// Register `studio.builder.ui.catalog.list` and `…catalog.schema`
/// onto [boot]. Pass the [catalog] service so callers can plug their
/// own loaders (e.g. a test catalogue) — defaults wire up to the
/// real `DslSpecLoader` + `VbuAtomSpecLoader` via
/// [BuilderCatalogService]'s default constructor.
void registerCatalogTools(
  mk.KernelServerHost boot, {
  required BuilderCatalogService catalog,
}) {
  boot.addTool(
    name: 'studio.builder.ui.catalog.list',
    description:
        'List every widget type available for ui authoring — '
        'standard mcp_ui_dsl 1.3 widgets plus the vbu_* atoms '
        'registered alongside them. Optional filters: `category` '
        '(exact match on yaml `category` field) and `source` '
        '(`standard` | `custom` | `all`). Returns '
        '`{widgets:[{type, category, source, summary}]}` — summary '
        'is the first line of each widget\'s description so the '
        'response stays small. Call `studio.builder.ui.catalog.'
        'schema` for full props / examples.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'category': <String, dynamic>{
          'type': 'string',
          'description':
              'Filter by category (e.g. `layout`, `atom`, `form`). '
              'Omit for all categories.',
        },
        'source': <String, dynamic>{
          'type': 'string',
          'enum': <String>['standard', 'custom', 'all'],
          'description': 'Filter by registry source. Default `all`.',
        },
      },
    },
    handler: (args) async {
      final category = args['category'] as String?;
      final source = args['source'] as String?;
      final widgets = await catalog.list(
        category: category == null || category.isEmpty ? null : category,
        source: source,
      );
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'widgets': <Map<String, dynamic>>[
                for (final w in widgets) w.toListJson(),
              ],
            }),
          ),
        ],
      );
    },
  );

  boot.addTool(
    name: 'studio.builder.ui.catalog.schema',
    description:
        'Return the full spec yaml of one widget type — `description`, '
        '`properties` (key / type / required / default / enum / '
        'description), and `children` arity that fall out of those '
        'props (e.g. `child: Widget` or `children: Array<Widget>`). '
        'Pass `withExamples: true` to include usage examples (DSL '
        'fragments) so the caller does not have to guess. Returns '
        '`{error: ...}` with `isError: true` when the type is not '
        'registered — try `studio.builder.ui.catalog.list` first to '
        'discover available types.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'type': <String, dynamic>{
          'type': 'string',
          'description':
              'Widget type as it appears in DSL (e.g. `linear`, '
              '`VbuTabStrip`, `markdown`).',
        },
        'withExamples': <String, dynamic>{
          'type': 'boolean',
          'description':
              'Include usage examples. Default false to keep the '
              'response compact.',
        },
      },
      'required': <String>['type'],
    },
    handler: (args) async {
      final type = args['type'];
      if (type is! String || type.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'code': 'missingRequired',
                'expected': 'type (string)',
                'actual': type?.runtimeType.toString(),
                'message': 'catalog.schema requires `type`.',
                'suggestion':
                    'Pass {"type": "<widget type>"} — call '
                    'studio.builder.ui.catalog.list to discover '
                    'available types.',
              }),
            ),
          ],
          isError: true,
        );
      }
      final withExamples = args['withExamples'] == true;
      final spec = await catalog.schema(type);
      if (spec == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'code': 'unknownType',
                'expected': 'a type registered in catalog.list',
                'actual': type,
                'message': 'No widget type named "$type" is registered.',
                'suggestion':
                    'Call studio.builder.ui.catalog.list to see '
                    'available types.',
              }),
            ),
          ],
          isError: true,
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(spec.toSchemaJson(withExamples: withExamples)),
          ),
        ],
      );
    },
  );

  // ── catalog.diag — loader path roots + silently-skipped yaml ──
  boot.addTool(
    name: 'studio.builder.ui.catalog.diag',
    description:
        'Return loader diagnostics for the widget catalogue — the '
        'resolved specs / workspace roots plus every yaml the '
        'standard loader silently skipped (root-not-map / '
        'type-field-missing / parse-error). Use this to spot specs '
        'that need a linter pass when `catalog.list` count looks '
        'lower than expected.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final diag = await catalog.diag();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(diag)),
        ],
      );
    },
  );
}
