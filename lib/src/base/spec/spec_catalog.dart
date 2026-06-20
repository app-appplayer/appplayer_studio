/// MCP UI DSL 1.3 spec catalog and validator surface.
///
/// vibe ships embedded copies of the hand-written app / page / theme
/// schemas (`embedded_schemas.g.dart` — regenerate via
/// `dart run tool/embed_schemas.dart`) so it can validate from any
/// working directory. The widget schema is already embedded by
/// `flutter_mcp_ui_core`. When vibe is launched from inside the
/// makemind workspace it prefers the on-disk schema files so a spec
/// edit is picked up without rebuilding.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart'
    as core
    show validateMcpUiDslWidget;
import 'package:json_schema/json_schema.dart';
import 'package:path/path.dart' as p;

import 'embedded_schemas.g.dart';
import 'widget_schema_catalog.dart';

/// Canonical current MCP UI DSL spec revision (full 3-part). Single
/// source of truth — every UI surface, every MCP tool response, and
/// every comment that names a version reads from here. Bump in lock
/// step with `specs/mcp_ui_dsl/spec/CHANGELOG.md` when the spec
/// publishes a new revision.
const String specVersion = '1.3.4';

/// Schema series — `major.minor` of [specVersion]. Used wherever the
/// 2-part form is required (schema directory, `$id` URL prefix,
/// embedded codegen). Derived from [specVersion] by trimming the
/// patch segment so the series stays automatically aligned: bumping
/// `specVersion` to `'1.3.5'` keeps `'1.3'`, bumping to `'1.4.0'`
/// flips both forms in lock step.
String get specSeriesVersion => specVersion.split('.').take(2).join('.');

/// Schema kinds vibe surfaces. Each maps to a file under
/// `specs/mcp_ui_dsl/spec/<version>/schema/`.
enum SchemaKind {
  app('app', 'app.schema.json', 'ApplicationDefinition'),
  page('page', 'page.schema.json', 'PageDefinition'),
  theme('theme', 'theme.schema.json', 'Theme tokens'),
  widget('widget', 'widgets.schema.json', 'Widget union (every renderable)');

  const SchemaKind(this.name, this.fileName, this.title);
  final String name;
  final String fileName;
  final String title;

  static SchemaKind? lookup(String name) {
    for (final k in values) {
      if (k.name == name) return k;
    }
    return null;
  }
}

class SchemaIssue {
  const SchemaIssue({required this.path, required this.message});

  /// JSON Pointer relative to the validated payload (e.g.
  /// `/templates/custom_01/content/children/0`). Empty string = root.
  final String path;
  final String message;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'message': message,
  };

  @override
  String toString() => path.isEmpty ? message : '$path: $message';
}

/// Catalog that resolves the spec directory, loads schemas on demand,
/// and validates JSON payloads against the loaded schemas.
class SpecCatalog {
  // Default `version` is null so we can resolve to [specSeriesVersion]
  // at construction (a const default can't call a getter). Callers
  // can still pin explicitly by passing a 2-part series string.
  SpecCatalog({String? repoRoot, String? version})
    : _repoRoot = repoRoot,
      _version = version ?? specSeriesVersion;

  String? _repoRoot;
  // Tri-state: null = haven't probed, false = no workspace, true = found.
  bool? _repoRootProbed;
  final String _version;

  /// Schema series this catalog is pinned to (e.g. `1.3`). Drives
  /// `schemaDir` and `$id` URL resolution. Exposed read-only so MCP
  /// tools can report the active series alongside [specVersion].
  String get seriesVersion => _version;
  final Map<SchemaKind, JsonSchema> _schemaCache = {};
  final Map<SchemaKind, String> _rawCache = {};

  /// Locate the workspace root (the directory containing
  /// `specs/mcp_ui_dsl`) by walking up from [anchor] (or the current
  /// directory). Cached after the first probe; absence is also cached.
  Future<String?> resolveRepoRoot([String? anchor]) async {
    if (_repoRootProbed == true) return _repoRoot;
    final start = Directory(anchor ?? Directory.current.path);
    var dir = start;
    while (true) {
      final probe = Directory(p.join(dir.path, 'specs', 'mcp_ui_dsl'));
      if (await probe.exists()) {
        _repoRoot = dir.path;
        _repoRootProbed = true;
        return _repoRoot;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) {
        _repoRootProbed = true;
        return null;
      }
      dir = parent;
    }
  }

  /// Absolute path to the schema directory for the pinned version, or
  /// null when the repo root could not be located.
  Future<String?> schemaDir([String? anchor]) async {
    final root = await resolveRepoRoot(anchor);
    if (root == null) return null;
    return p.join(root, 'specs', 'mcp_ui_dsl', 'spec', _version, 'schema');
  }

  /// Read the raw JSON Schema text for [kind]. Prefers the on-disk
  /// spec files when vibe is running inside the workspace (so spec
  /// edits flow without a rebuild); falls back to the constants
  /// embedded at build time otherwise. The widget kind always reads
  /// from the runtime's generated constant via the WidgetSchemaCatalog.
  Future<String> readSchemaText(SchemaKind kind, {String? anchor}) async {
    final cached = _rawCache[kind];
    if (cached != null) return cached;
    final dir = await schemaDir(anchor);
    if (dir != null) {
      final file = File(p.join(dir, kind.fileName));
      if (await file.exists()) {
        final raw = await file.readAsString();
        _rawCache[kind] = raw;
        return raw;
      }
    }
    final embedded = embeddedSchemasByKind[kind.name];
    if (embedded != null) {
      _rawCache[kind] = embedded;
      return embedded;
    }
    throw StateError(
      'spec catalog: no on-disk file and no embedded copy for '
      '${kind.fileName}',
    );
  }

  /// Compile and cache the JsonSchema for [kind].
  ///
  /// The spec schemas reference one another via remote `$id` URIs
  /// (`https://specs.makemind.com/mcp_ui_dsl/<v>/...`). The supplied
  /// [RefProvider] resolves those back to either the on-disk files
  /// (workspace dev mode) or the embedded constants (deployed mode).
  Future<JsonSchema> _schemaFor(SchemaKind kind, {String? anchor}) async {
    final cached = _schemaCache[kind];
    if (cached != null) return cached;
    final raw = await readSchemaText(kind, anchor: anchor);
    final dir = await schemaDir(anchor);
    final urlPrefix = 'https://specs.makemind.com/mcp_ui_dsl/$_version/';
    final refProvider = RefProvider.async((String url) async {
      if (!url.startsWith(urlPrefix)) return null;
      final tail = url.substring(urlPrefix.length);
      // Disk first when available (matches readSchemaText precedence).
      if (dir != null) {
        final file = File(p.join(dir, tail));
        if (await file.exists()) {
          return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        }
      }
      // Fall back to embedded — keyed by kind name (e.g.
      // `app.schema.json` → `app`). Anything outside the three
      // hand-written kinds is unresolvable here on purpose; the
      // widget union is loaded separately via the runtime constant.
      for (final k in SchemaKind.values) {
        if (tail == k.fileName) {
          final embedded = embeddedSchemasByKind[k.name];
          if (embedded != null) {
            return jsonDecode(embedded) as Map<String, dynamic>;
          }
        }
      }
      return null;
    });
    final compiled = await JsonSchema.createAsync(
      raw,
      refProvider: refProvider,
    );
    _schemaCache[kind] = compiled;
    return compiled;
  }

  /// Validate [payload] against the schema for [kind]. Widget validation
  /// uses the runtime's compiled validator (`validateMcpUiDslWidget`)
  /// since the widget union is large enough that JsonSchema's reflection
  /// path is noticeably slower; everything else goes through json_schema.
  Future<List<SchemaIssue>> validate(
    Object? payload,
    SchemaKind kind, {
    String? anchor,
  }) async {
    if (kind == SchemaKind.widget) {
      if (payload is! Map<String, dynamic>) {
        return <SchemaIssue>[
          const SchemaIssue(path: '', message: 'expected a JSON object'),
        ];
      }
      // Special-case unknown widget type before the runtime validator —
      // it would otherwise dump the full anyOf with all widget refs into
      // the message. The catalog answer is a one-liner the LLM can act
      // on directly.
      final type = payload['type'];
      if (type is String && !WidgetSchemaCatalog.instance.knows(type)) {
        return <SchemaIssue>[
          SchemaIssue(path: '', message: "unknown widget type '$type'"),
        ];
      }
      final result = core.validateMcpUiDslWidget(payload);
      if (result.isValid) return const <SchemaIssue>[];
      return _dedupe(
        result.errors
            .map(
              (e) =>
                  SchemaIssue(path: e.path, message: _trimMessage(e.message)),
            )
            .toList(),
      );
    }
    final schema = await _schemaFor(kind, anchor: anchor);
    final result = schema.validate(payload);
    if (result.isValid) return const <SchemaIssue>[];
    return _dedupe(
      result.errors
          .map(
            (e) => SchemaIssue(
              path: e.instancePath,
              message: _trimMessage(e.message),
            ),
          )
          .toList(),
    );
  }

  /// Drop trailing `from {...}` object-dumps that json_schema appends
  /// for "required" / "additionalProperties" violations. The path
  /// already locates the offending node; the dump is noise for an LLM.
  static String _trimMessage(String msg) {
    final marker = ' from {';
    final i = msg.indexOf(marker);
    if (i <= 0) return msg;
    return msg.substring(0, i);
  }

  /// De-duplicate identical (path, message) pairs. json_schema's
  /// anyOf branch validation often surfaces the same root-level
  /// problem at multiple paths (`/ui` + `/ui/routes` for one missing
  /// `routes`).
  static List<SchemaIssue> _dedupe(List<SchemaIssue> issues) {
    final seen = <String>{};
    final out = <SchemaIssue>[];
    for (final issue in issues) {
      final key = '${issue.path} ${issue.message}';
      if (seen.add(key)) out.add(issue);
    }
    return out;
  }

  /// Lint a full canonical bundle: validate the application body,
  /// every page, every template `content`, and the dashboard content.
  /// Each issue is prefixed with a stable JSON Pointer so authors can
  /// jump to the offending node.
  Future<List<SchemaIssue>> lintCanonical(
    Map<String, dynamic> canonical, {
    String? anchor,
  }) async {
    final issues = <SchemaIssue>[];

    final ui = canonical['ui'];
    if (ui is! Map<String, dynamic>) {
      issues.add(
        const SchemaIssue(
          path: '/ui',
          message: 'missing or non-object `ui` block',
        ),
      );
      return issues;
    }

    // ApplicationDefinition body — validate against app schema.
    issues.addAll(
      (await validate(
        ui,
        SchemaKind.app,
        anchor: anchor,
      )).map((e) => _prefix('/ui', e)),
    );

    // Templates: each entry's `content` widget tree is the user's authoring
    // surface. Validate via the widget union.
    final templates = ui['templates'];
    if (templates is Map) {
      for (final entry in templates.entries) {
        final id = entry.key;
        final raw = entry.value;
        if (raw is! Map) continue;
        final content = raw['content'];
        if (content is Map<String, dynamic>) {
          issues.addAll(
            (await validate(
              content,
              SchemaKind.widget,
              anchor: anchor,
            )).map((e) => _prefix('/ui/templates/$id/content', e)),
          );
        }
      }
    }

    // Dashboard content: optional, validated via widget schema.
    final dashboard = ui['dashboard'];
    if (dashboard is Map) {
      final content = dashboard['content'];
      if (content is Map<String, dynamic>) {
        issues.addAll(
          (await validate(
            content,
            SchemaKind.widget,
            anchor: anchor,
          )).map((e) => _prefix('/ui/dashboard/content', e)),
        );
      }
    }

    // Pages: validate each page via page schema, then drill into content
    // via widget schema for richer messages.
    final pages = ui['pages'];
    if (pages is Map) {
      for (final entry in pages.entries) {
        final id = entry.key;
        final page = entry.value;
        if (page is! Map<String, dynamic>) continue;
        issues.addAll(
          (await validate(
            page,
            SchemaKind.page,
            anchor: anchor,
          )).map((e) => _prefix('/ui/pages/$id', e)),
        );
        final content = page['content'];
        if (content is Map<String, dynamic>) {
          issues.addAll(
            (await validate(
              content,
              SchemaKind.widget,
              anchor: anchor,
            )).map((e) => _prefix('/ui/pages/$id/content', e)),
          );
        }
      }
    }

    return issues;
  }

  static SchemaIssue _prefix(String prefix, SchemaIssue inner) {
    final tail = inner.path;
    return SchemaIssue(
      path: tail.isEmpty ? prefix : '$prefix$tail',
      message: inner.message,
    );
  }
}

/// Encode a list of issues as the MCP-friendly response payload.
Map<String, dynamic> issuesPayload(List<SchemaIssue> issues) {
  return <String, dynamic>{
    'ok': issues.isEmpty,
    'count': issues.length,
    'issues': issues.map((e) => e.toJson()).toList(),
  };
}
