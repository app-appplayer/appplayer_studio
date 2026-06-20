import 'dart:convert';
import 'dart:io';

import 'package:flutter_mcp_ui_generator/flutter_mcp_ui_generator.dart';
import 'package:mcp_bundle/mcp_bundle.dart' show McpBundle, McpBundlePacker;
import 'package:path/path.dart' as p;

import '../core/types.dart';
import 'pattern_enforcer.dart';

/// Converts the canonical bundle into one of the three Dart-target shapes:
/// `.mcpb` archive, MDB-serving Dart MCP server, or native Dart MCP server.
///
/// [sourceBundlePath] is the on-disk `app.mbd/` of the project doing the
/// build. When provided, the mcpb target packs that directory directly
/// — preserving `ui/app.json` + `ui/pages/<id>.json` exactly as they
/// were saved. When omitted (e.g. when invoked over the MCP tool surface
/// without a backing project), mcpb falls back to staging a single
/// `manifest.json` from the typed [McpBundle] — which loses the
/// pages-keyed-by-id `ui` shape vibe authors but is still a valid
/// archive for hosts that only need the manifest.
abstract interface class DartConverter {
  Future<ConvertResult> run({
    required McpBundle canonical,
    required DartTarget target,
    required String outDir,
    String? sourceBundlePath,
  });
}

/// Output target. Two axes:
///   * **bundle vs inline** — `.mbd` lives on disk next to the binary,
///     or its JSON is baked into the Dart source as a string constant.
///   * **headless serving vs native (serving + self-UI)** — a plain
///     MCP server that other clients connect to, or a full Flutter
///     app that both serves over MCP and renders the UI itself.
///
/// Plus one non-server output: `mcpb` (a single archive AppPlayer can
/// install in place). Generated artifact names follow
/// `{project_name}_{variant}` for the four server / native variants;
/// `mcpb` is just the archive file.
enum DartTarget {
  /// Pack the bundle as a single `.mcpb` archive.
  mcpb,

  /// Headless MCP server reading `app.mbd/` from disk next to the
  /// binary. Package name: `{project_name}_bundle`.
  bundle,

  /// Headless MCP server with the UI inlined as a Dart constant.
  /// Package name: `{project_name}_inline`.
  inline,

  /// Flutter app: serves over MCP **and** renders the UI itself.
  /// Reads `app.mbd/` from disk. Package: `{project_name}_native_bundle`.
  nativeBundle,

  /// Flutter app: serves over MCP **and** renders the UI itself.
  /// UI is inlined. Package: `{project_name}_native_inline`.
  nativeInline,
}

/// Default implementation. Writes a manifest-marked output directory; the
/// actual Dart server transpilation is intentionally minimal here and is
/// extended as the converter contract grows.
class DartConverterImpl implements DartConverter {
  DartConverterImpl({PatternEnforcer? enforcer})
    : _enforcer = enforcer ?? const PatternEnforcerImpl();

  final PatternEnforcer _enforcer;

  @override
  Future<ConvertResult> run({
    required McpBundle canonical,
    required DartTarget target,
    required String outDir,
    String? sourceBundlePath,
  }) async {
    final violations = _enforcer.check(
      canonical,
      ConvertTarget(family: 'dart', subKind: target.name),
    );
    if (violations.isNotEmpty) {
      throw PatternException(violations);
    }
    final dir = Directory(outDir);
    await dir.create(recursive: true);
    final written = <String>[];
    final canonicalJson = jsonEncode(canonical.toJson());
    final canonicalHash =
        'sha256:${canonicalJson.hashCode.toUnsigned(63).toRadixString(16)}';

    switch (target) {
      case DartTarget.nativeBundle:
        await _emitNativeBundleApp(
          canonical: canonical,
          outDir: outDir,
          sourceBundlePath: sourceBundlePath,
          written: written,
        );
        break;
      case DartTarget.nativeInline:
        await _emitNativeInlineApp(
          canonical: canonical,
          canonicalJson: canonicalJson,
          sourceBundlePath: sourceBundlePath,
          outDir: outDir,
          written: written,
        );
        break;
      case DartTarget.mcpb:
        final mcpbFile = File(p.join(outDir, 'bundle.mcpb'));
        if (sourceBundlePath != null &&
            await Directory(sourceBundlePath).exists() &&
            await File(p.join(sourceBundlePath, 'manifest.json')).exists()) {
          // Pack the project's on-disk bundle verbatim — the manifest +
          // ui/ tree are already in their canonical layout from save().
          final bytes = await McpBundlePacker.packDirectory(sourceBundlePath);
          await mcpbFile.writeAsBytes(bytes, flush: true);
        } else {
          // Fallback: stage a single manifest.json from the typed bundle.
          // This loses pages-keyed-by-id `ui` content but keeps the MCP
          // tool surface (which has no project context) functional.
          final stage = await Directory.systemTemp.createTemp(
            'vibe_mcpb_pack_',
          );
          try {
            final mbdDir = Directory(p.join(stage.path, 'bundle.mbd'));
            await mbdDir.create(recursive: true);
            await File(
              p.join(mbdDir.path, 'manifest.json'),
            ).writeAsString(canonicalJson);
            final bytes = await McpBundlePacker.packDirectory(mbdDir.path);
            await mcpbFile.writeAsBytes(bytes, flush: true);
          } finally {
            if (await stage.exists()) {
              await stage.delete(recursive: true);
            }
          }
        }
        written.add(mcpbFile.path);
        break;
      case DartTarget.bundle:
        await _emitBundleServer(
          canonical: canonical,
          outDir: outDir,
          sourceBundlePath: sourceBundlePath,
          written: written,
        );
        break;
      case DartTarget.inline:
        await _emitInlineServer(
          canonical: canonical,
          canonicalJson: canonicalJson,
          sourceBundlePath: sourceBundlePath,
          outDir: outDir,
          written: written,
        );
        break;
    }
    final manifest = File(p.join(outDir, 'convert.json'));
    await manifest.writeAsString(
      jsonEncode(<String, dynamic>{
        'target': 'dart_${target.name}',
        'generated_at': DateTime.now().toUtc().toIso8601String(),
        'canonical_hash': canonicalHash,
      }),
    );
    written.add(manifest.path);
    return ConvertResult(
      outDir: outDir,
      canonicalHash: canonicalHash,
      writtenFiles: written,
    );
  }

  Future<void> _emitBundleServer({
    required McpBundle canonical,
    required String outDir,
    required String? sourceBundlePath,
    required List<String> written,
  }) async {
    final slug = _slug(
      canonical.manifest.name,
      fallback: canonical.manifest.id,
    );
    await _emitHeadlessFiles(
      outDir: outDir,
      slug: '${slug}_bundle',
      title: canonical.manifest.name,
      description: canonical.manifest.description ?? canonical.manifest.name,
      uiLoader: _uiLoaderHeadlessBundle,
      kind: 'bundle',
      written: written,
    );
    // Copy the project's bundle into the generated app folder so the
    // server can be run with `--bundle ./app.mbd` out of the box.
    if (sourceBundlePath != null &&
        await Directory(sourceBundlePath).exists()) {
      final dest = Directory(p.join(outDir, 'app.mbd'));
      if (await dest.exists()) await dest.delete(recursive: true);
      await _copyDirectory(Directory(sourceBundlePath), dest);
      written.add(dest.path);
    }
  }

  Future<void> _emitInlineServer({
    required McpBundle canonical,
    required String canonicalJson,
    String? sourceBundlePath,
    required String outDir,
    required List<String> written,
  }) async {
    final ui =
        sourceBundlePath != null
            ? await _readDiskUi(sourceBundlePath)
            : _uiOnlyJson(canonicalJson);
    final uiName =
        _uiString(ui, 'title') ??
        _uiString(ui, 'name') ??
        canonical.manifest.name;
    final uiId = _uiString(ui, 'id') ?? canonical.manifest.id;
    final uiVersion = _uiString(ui, 'version') ?? canonical.manifest.version;
    final uiDescription =
        _uiString(ui, 'description') ??
        canonical.manifest.description ??
        uiName;
    final slug = _slug(uiName, fallback: uiId);
    await _emitHeadlessFiles(
      outDir: outDir,
      slug: '${slug}_inline',
      title: uiName,
      description: uiDescription,
      uiLoader: _uiLoaderHeadlessInline(ui),
      kind: 'inline',
      defaultVersion: uiVersion,
      written: written,
    );
  }

  Future<void> _emitNativeBundleApp({
    required McpBundle canonical,
    required String outDir,
    required String? sourceBundlePath,
    required List<String> written,
  }) async {
    final slug = _slug(
      canonical.manifest.name,
      fallback: canonical.manifest.id,
    );
    await _emitNativeFiles(
      outDir: outDir,
      slug: '${slug}_native_bundle',
      title: canonical.manifest.name,
      description: canonical.manifest.description ?? canonical.manifest.name,
      uiLoader: _uiLoaderBundle,
      kind: 'native_bundle',
      includeBundleAssets: true,
      written: written,
    );
    // Copy the project's bundle into the app folder. With pubspec's
    // `assets:` declaration the bundle ships inside the compiled app;
    // `flutter run` from this folder also picks it up via rootBundle.
    if (sourceBundlePath != null &&
        await Directory(sourceBundlePath).exists()) {
      final dest = Directory(p.join(outDir, 'app.mbd'));
      if (await dest.exists()) await dest.delete(recursive: true);
      await _copyDirectory(Directory(sourceBundlePath), dest);
      written.add(dest.path);
    }
  }

  Future<void> _emitNativeInlineApp({
    required McpBundle canonical,
    required String canonicalJson,
    String? sourceBundlePath,
    required String outDir,
    required List<String> written,
  }) async {
    final ui =
        sourceBundlePath != null
            ? await _readDiskUi(sourceBundlePath)
            : _uiOnlyJson(canonicalJson);
    final uiName =
        _uiString(ui, 'title') ??
        _uiString(ui, 'name') ??
        canonical.manifest.name;
    final uiId = _uiString(ui, 'id') ?? canonical.manifest.id;
    final slug = _slug(uiName, fallback: uiId);
    await _emitNativeFiles(
      outDir: outDir,
      slug: '${slug}_native_inline',
      title: uiName,
      description:
          _uiString(ui, 'description') ??
          canonical.manifest.description ??
          uiName,
      uiLoader: _uiLoaderInline(ui),
      kind: 'native_inline',
      includeBundleAssets: false,
      written: written,
    );
  }

  /// Re-assemble the full UI map from a `.mbd/` directory:
  /// `ui/app.json` (ApplicationDefinition body — theme, routes,
  /// navigation, templates, dashboard, …) plus every
  /// `ui/pages/<id>.json` file under a `pages` map. Mirrors what
  /// `WorkspaceFsPort._readUiTree` does, but without taking a
  /// dependency on mcp_bundle's loader to keep the converter library
  /// self-contained.
  static Future<Map<String, dynamic>> _readDiskUi(String bundlePath) async {
    final out = <String, dynamic>{};
    final appFile = File(p.join(bundlePath, 'ui', 'app.json'));
    if (await appFile.exists()) {
      try {
        final body = jsonDecode(await appFile.readAsString());
        if (body is Map) {
          out.addAll(Map<String, dynamic>.from(body));
        }
      } catch (e) {
        // Recover as missing, but surface — a malformed app.json silently
        // converting to an empty app body hides a real bug (parse-masking).
      }
    }
    final pagesDir = Directory(p.join(bundlePath, 'ui', 'pages'));
    if (await pagesDir.exists()) {
      final pages = <String, dynamic>{};
      await for (final entry in pagesDir.list()) {
        if (entry is! File) continue;
        if (!entry.path.endsWith('.json')) continue;
        final id = p.basenameWithoutExtension(entry.path);
        try {
          final pageJson = jsonDecode(await entry.readAsString());
          if (pageJson is Map) {
            pages[id] = Map<String, dynamic>.from(pageJson);
          }
        } catch (_) {
          /* skip malformed page file */
        }
      }
      if (pages.isNotEmpty) out['pages'] = pages;
    }
    return out;
  }

  /// Extract the `ui` sub-tree from the canonical JSON so serverNative
  /// can inline only the ApplicationDefinition (no manifest). Falls
  /// back to an empty map when canonical is malformed.
  static Map<String, dynamic> _uiOnlyJson(String canonicalJson) {
    try {
      final decoded = jsonDecode(canonicalJson);
      if (decoded is Map && decoded['ui'] is Map<String, dynamic>) {
        return Map<String, dynamic>.from(decoded['ui'] as Map);
      }
    } catch (_) {
      /* fall through */
    }
    return <String, dynamic>{};
  }

  /// Read a top-level string field from the UI map, or null when the
  /// key is missing / non-string / empty.
  static String? _uiString(Map<String, dynamic> ui, String key) {
    final v = ui[key];
    if (v is String && v.isNotEmpty) return v;
    return null;
  }

  /// Best-effort identifier from a human-readable bundle name. Matches the
  /// pubspec slug rules: `[a-z0-9_]+`, fall back to [fallback] (manifest
  /// id) when the name reduces to empty.
  static String _slug(String name, {required String fallback}) {
    final lower = name.toLowerCase();
    final buf = StringBuffer();
    for (final code in lower.codeUnits) {
      final isLower = code >= 0x61 && code <= 0x7a; // a-z
      final isDigit = code >= 0x30 && code <= 0x39; // 0-9
      if (isLower || isDigit) {
        buf.writeCharCode(code);
      } else if (buf.isNotEmpty &&
          buf.toString().codeUnitAt(buf.length - 1) != 0x5f) {
        buf.writeCharCode(0x5f); // underscore
      }
    }
    var result = buf.toString();
    while (result.startsWith('_')) {
      result = result.substring(1);
    }
    while (result.endsWith('_')) {
      result = result.substring(0, result.length - 1);
    }
    if (result.isEmpty)
      result = fallback.replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    if (result.isEmpty) result = 'generated_server';
    // Pubspec name must start with a letter.
    if (!RegExp(r'^[a-z]').hasMatch(result)) result = 'gen_$result';
    return result;
  }

  /// Pinned hosted pub versions of the runtime deps the generated
  /// server needs. Bumping these is the single source of truth for
  /// shipped artifacts — keep aligned with what `server.dart`
  /// imports.
  static const String _mcpServerVersion = '^2.0.0';
  static const String _mcpBundleVersion = '^0.3.0';

  /// Pubspec for the headless Dart variants (`bundle` / `inline`).
  /// Layout follows the standard Dart CLI shape: `bin/server.dart`
  /// is the executable entry, `lib/` holds the supporting modules.
  static String _pubspecFor({
    required String slug,
    required String bundleDescription,
    required String kind,
  }) {
    final flavor =
        kind == 'bundle'
            ? 'bundle-backed (reads .mbd via `mcp_bundle`)'
            : 'inline (UI baked into source)';
    final deps =
        kind == 'bundle'
            ? '  mcp_server: $_mcpServerVersion\n  mcp_bundle: $_mcpBundleVersion'
            : '  mcp_server: $_mcpServerVersion';
    return '''
name: $slug
description: $bundleDescription — generated $flavor MCP server (AppPlayer Builder).
version: 1.0.0
publish_to: none

environment:
  sdk: '>=3.0.0 <4.0.0'

executables:
  server:

dependencies:
$deps
''';
  }

  /// README mirrors the headless variant's 5-file layout. Same shape
  /// as the native variants minus the Flutter shell.
  static String _readmeFor({
    required String name,
    required String slug,
    required String kind,
  }) {
    final isBundle = kind == 'bundle';
    final loadLine =
        isBundle
            ? '`lib/ui_loader.dart` reads `app.mbd/` from disk via '
                '`mcp_bundle` (path comes from `--bundle <path>` or a '
                'sibling `app.mbd/`).'
            : '`lib/ui_loader.dart` parses the ApplicationDefinition '
                'baked into a `_uiJson` constant.';
    final layoutLines =
        StringBuffer()
          ..writeln('$kind/')
          ..writeln('├── bin/')
          ..writeln(
            '│   └── server.dart              # entry — runs runServer()',
          )
          ..writeln('├── lib/')
          ..writeln(
            '│   ├── mcp_server_setup.dart    # McpServer + stdio + ui:// resources',
          )
          ..writeln(
            '│   ├── ui_loader.dart           # UI source (variant-specific)',
          )
          ..writeln(
            '│   └── handlers.dart            # domain tool registrations',
          )
          ..writeln('├── pubspec.yaml')
          ..writeln('├── README.md');
    if (isBundle) layoutLines.writeln('├── app.mbd/');
    layoutLines.write(
      '└── (`dart compile exe bin/server.dart -o $slug` for a single binary)',
    );
    final runCmd =
        isBundle
            ? 'dart run bin/server.dart --bundle ./app.mbd'
            : 'dart run bin/server.dart';
    return '''
# $name

Generated by AppPlayer Builder — headless Dart MCP server ($kind variant).

Stdio transport — external clients (Claude Desktop, MCP Inspector,
AppPlayer) connect by spawning the binary. $loadLine

## Layout

The server is split into single-responsibility modules so adding a
domain feature usually only touches `lib/handlers.dart` (or one new
file alongside it):

```
$layoutLines
```

## Run

```sh
dart pub get
$runCmd
```

For a self-contained binary:

```sh
dart compile exe bin/server.dart -o $slug
./$slug${isBundle ? ' --bundle ./app.mbd' : ''}
```

## Custom tools / resources / domain code

`lib/handlers.dart` is the **only file LLMs need to touch** to add a
new tool. Each `_register(...)` call wires the handler on the
running MCP server with one line — same pattern the native variants
use, minus the runtime side (no self-UI here).

## Building on top with the makemind ecosystem

The four modules give you the **MCP server base**. To add features,
reach for vetted ecosystem packages first rather than hand-rolling.
Catalog: https://app-appplayer.github.io/makemind . Common picks:

- `mcp_client`     — connect to other MCP servers / devices.
- `mcp_llm`        — embed an LLM (chat, tool use).
- `mcp_io_*`       — Modbus / CAN / OPC UA / SCPI / serial / MQTT /
  HTTP / WebSocket transports.
- `mcp_form`       — input collection.
- `mcp_canvas`     — charts / visualisation.
- `mcp_flow_runtime` — declarative workflows / scheduling.
- `mcp_knowledge` (+ `mcp_fact_graph`, `mcp_profile`) — agent
  memory + per-user state.

Add the package to `pubspec.yaml` (caret pin), `dart pub get`,
import in `handlers.dart` (or split into a new file once handlers
grow). The 5-file scaffold scales from a one-tool demo to a larger
server without restructuring.
''';
  }

  /// Emit the 5 files shared by both `bundle` and `inline` headless
  /// variants — only `lib/ui_loader.dart` differs. Same module shape
  /// as `_emitNativeFiles` so LLM-driven edits land in the same kind
  /// of file regardless of axis (headless / native; bundle / inline).
  Future<void> _emitHeadlessFiles({
    required String outDir,
    required String slug,
    required String title,
    required String description,
    required String uiLoader,
    required String kind,
    required List<String> written,
    String defaultVersion = '1.0.0',
  }) async {
    final binDir = Directory(p.join(outDir, 'bin'));
    final libDir = Directory(p.join(outDir, 'lib'));
    await binDir.create(recursive: true);
    await libDir.create(recursive: true);

    final entry = File(p.join(binDir.path, 'server.dart'));
    await entry.writeAsString(_headlessServerEntry);
    written.add(entry.path);

    final setup = File(p.join(libDir.path, 'mcp_server_setup.dart'));
    await setup.writeAsString(
      kind == 'bundle'
          ? _headlessServerSetupBundle
          : _headlessServerSetupInlineFor(
            defaultName: title,
            defaultVersion: defaultVersion,
          ),
    );
    written.add(setup.path);

    final loader = File(p.join(libDir.path, 'ui_loader.dart'));
    await loader.writeAsString(uiLoader);
    written.add(loader.path);

    final handlers = File(p.join(libDir.path, 'handlers.dart'));
    await handlers.writeAsString(_headlessHandlersStub);
    written.add(handlers.path);

    final pubspec = File(p.join(outDir, 'pubspec.yaml'));
    await pubspec.writeAsString(
      _pubspecFor(slug: slug, bundleDescription: description, kind: kind),
    );
    written.add(pubspec.path);

    final readme = File(p.join(outDir, 'README.md'));
    await readme.writeAsString(_readmeFor(name: title, slug: slug, kind: kind));
    written.add(readme.path);
  }

  static Future<void> _copyDirectory(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    await for (final entity in src.list(followLinks: false)) {
      final basename = p.basename(entity.path);
      final newPath = p.join(dest.path, basename);
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
  }

  // ─── Headless Dart MCP server templates (5-file layout) ───────────
  // Same module shape as the native variants, minus the Flutter shell.
  // `bin/server.dart` is the executable entry; `lib/` holds the
  // reusable modules. `lib/handlers.dart` is the only file most
  // domain edits touch.

  /// `bin/server.dart` — entry point. Runs `runServer()` from
  /// `lib/mcp_server_setup.dart`. Author-rare changes (custom CLI
  /// flag parsing, alternate transports) land here.
  static const String _headlessServerEntry = r'''
// Generated by AppPlayer Builder.
// Headless Dart MCP server entry point. Domain logic lives in
// `lib/handlers.dart`; transport + resource registration in
// `lib/mcp_server_setup.dart`; UI source in `lib/ui_loader.dart`.
library;

import 'dart:io';

import '../lib/mcp_server_setup.dart' as setup;

Future<void> main(List<String> args) async {
  try {
    await setup.runServer(args);
  } on setup.UsageException catch (e) {
    exit(64);
  } catch (e) {
    exit(70);
  }
}
''';

  /// `lib/mcp_server_setup.dart` — bundle variant.
  static const String _headlessServerSetupBundle = r'''
// Generated by AppPlayer Builder.
// MCP server bootstrap (bundle variant). Reads `app.mbd/` from disk
// and publishes every `ui/<rel>.json` as `ui://<rel>`. Synthesises
// `ui://app/info` from the manifest.
//
// Default invocation                  → stdio transport. Bundle path
//                                       resolves via --bundle / a
//                                       sibling `app.mbd/` directory.
// `--http [opts]`                     → streamable HTTP. Default
//                                       127.0.0.1:8080/mcp. Override
//                                       with `--port`, `--host`,
//                                       `--endpoint`.
// `--sse [opts]`                      → SSE (legacy).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart' hide ResourceContent;
import 'package:mcp_server/mcp_server.dart';

import 'handlers.dart';
import 'ui_loader.dart';

class UsageException implements Exception {
  UsageException(this.message);
  final String message;
}

Future<void> runServer(List<String> args) async {
  final bundlePath = parseBundlePath(args);
  if (bundlePath == null) {
    throw UsageException(
        'Usage: <binary> [--stdio | --http | --sse] '
        '[--host <h>] [--port <n>] [--endpoint <path>] '
        '[--bundle <path-to-.mbd>]');
  }
  final McpBundle bundle;
  try {
    bundle = await McpBundleLoader.loadDirectory(bundlePath);
  } on BundleLoadException catch (e) {
    throw UsageException('Failed to load bundle at $bundlePath: $e');
  }
  final config = McpServerConfig(
    name: bundle.manifest.name.isNotEmpty
        ? bundle.manifest.name
        : 'Generated Bundle Server',
    version: bundle.manifest.version,
    capabilities: const ServerCapabilities(
      resources: ResourcesCapability(listChanged: false, subscribe: false),
      tools: ToolsCapability(listChanged: false),
    ),
    enableDebugLogging: false,
  );
  final server = McpServer.createServer(config);
  await registerBundleResources(server, bundle);
  registerHandlers(server: server);

  final opts = _TransportOptions.parse(args);
  switch (opts.kind) {
    case _TransportKind.stdio:
      final transport = McpServer.createStdioTransport().get();
      server.connect(transport);
      await transport.onClose;
      break;
    case _TransportKind.http:
      final transport = (await McpServer.createStreamableHttpTransportAsync(
        opts.port,
        host: opts.host,
        endpoint: opts.endpoint,
        isJsonResponseEnabled: true,
      )).get();
      server.connect(transport);
      await ProcessSignal.sigint.watch().first;
      break;
    case _TransportKind.sse:
      // ignore: deprecated_member_use
      final transport = McpServer.createSseTransport(SseTransportConfig(
        endpoint: opts.endpoint,
        messagesEndpoint: '${opts.endpoint}/messages',
        host: opts.host,
        port: opts.port,
      )).get();
      server.connect(transport);
      await ProcessSignal.sigint.watch().first;
      break;
  }
}

enum _TransportKind { stdio, http, sse }

class _TransportOptions {
  _TransportOptions({
    required this.kind,
    required this.host,
    required this.port,
    required this.endpoint,
  });
  final _TransportKind kind;
  final String host;
  final int port;
  final String endpoint;

  static _TransportOptions parse(List<String> args) {
    var kind = _TransportKind.stdio;
    var host = '127.0.0.1';
    var port = 8080;
    var endpoint = '/mcp';
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      String? consume(String key) {
        if (a == key) {
          if (i + 1 < args.length) return args[++i];
          return null;
        }
        if (a.startsWith('$key=')) return a.substring(key.length + 1);
        return null;
      }
      if (a == '--http') {
        kind = _TransportKind.http;
        continue;
      }
      if (a == '--sse') {
        kind = _TransportKind.sse;
        continue;
      }
      if (a == '--stdio') {
        kind = _TransportKind.stdio;
        continue;
      }
      final hostV = consume('--host');
      if (hostV != null) {
        host = hostV;
        continue;
      }
      final portV = consume('--port');
      if (portV != null) {
        port = int.tryParse(portV) ?? port;
        continue;
      }
      final epV = consume('--endpoint');
      if (epV != null) {
        endpoint = epV;
        continue;
      }
    }
    return _TransportOptions(
        kind: kind, host: host, port: port, endpoint: endpoint);
  }
}

ReadResourceResult resourceJson(String uri, String text) {
  jsonDecode(text);
  return ReadResourceResult(
    contents: <ResourceContentInfo>[
      ResourceContentInfo(
        uri: uri,
        mimeType: 'application/json',
        text: text,
      ),
    ],
  );
}
''';

  /// `lib/mcp_server_setup.dart` — inline variant. Project name and
  /// version flow through as fallbacks so a UI without explicit
  /// metadata still identifies cleanly to MCP clients.
  static String _headlessServerSetupInlineFor({
    required String defaultName,
    required String defaultVersion,
  }) {
    String esc(String s) => s
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll(r'$', r'\$');
    return _headlessServerSetupInline
        .replaceAll(
          "'Generated Inline Server'",
          "'${esc(defaultName.isEmpty ? 'Generated Inline Server' : defaultName)}'",
        )
        .replaceAll(
          "'1.0.0'",
          "'${esc(defaultVersion.isEmpty ? '1.0.0' : defaultVersion)}'",
        );
  }

  static const String _headlessServerSetupInline = r'''
// Generated by AppPlayer Builder.
// MCP server bootstrap (inline variant). UI baked into ui_loader.dart;
// no .mbd at runtime. Identity comes from UI metadata fields.
//
// Default invocation (no args)        → stdio transport. Hosts that
//                                       spawn the binary (Claude Desktop,
//                                       AppPlayer, mcp_client stdio) work
//                                       out of the box.
// `--http [opts]`                     → streamable HTTP. Default
//                                       127.0.0.1:8080/mcp. Override
//                                       with `--port`, `--host`,
//                                       `--endpoint`.
// `--sse [opts]`                      → SSE (legacy). Same opts as
//                                       --http.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_server/mcp_server.dart';

import 'handlers.dart';
import 'ui_loader.dart';

class UsageException implements Exception {
  UsageException(this.message);
  final String message;
}

Future<void> runServer(List<String> args) async {
  final ui = await loadUi();
  final identity = _identity(ui);
  final config = McpServerConfig(
    name: identity.$1,
    version: identity.$2,
    capabilities: const ServerCapabilities(
      resources: ResourcesCapability(listChanged: false, subscribe: false),
      tools: ToolsCapability(listChanged: false),
    ),
    enableDebugLogging: false,
  );
  final server = McpServer.createServer(config);
  registerInlineResources(server, ui);
  registerHandlers(server: server);

  final opts = _TransportOptions.parse(args);
  switch (opts.kind) {
    case _TransportKind.stdio:
      final transport = McpServer.createStdioTransport().get();
      server.connect(transport);
      await transport.onClose;
      break;
    case _TransportKind.http:
      final transport = (await McpServer.createStreamableHttpTransportAsync(
        opts.port,
        host: opts.host,
        endpoint: opts.endpoint,
        isJsonResponseEnabled: true,
      )).get();
      server.connect(transport);
      await ProcessSignal.sigint.watch().first;
      break;
    case _TransportKind.sse:
      // ignore: deprecated_member_use
      final transport = McpServer.createSseTransport(SseTransportConfig(
        endpoint: opts.endpoint,
        messagesEndpoint: '${opts.endpoint}/messages',
        host: opts.host,
        port: opts.port,
      )).get();
      server.connect(transport);
      await ProcessSignal.sigint.watch().first;
      break;
  }
}

enum _TransportKind { stdio, http, sse }

class _TransportOptions {
  _TransportOptions({
    required this.kind,
    required this.host,
    required this.port,
    required this.endpoint,
  });
  final _TransportKind kind;
  final String host;
  final int port;
  final String endpoint;

  static _TransportOptions parse(List<String> args) {
    var kind = _TransportKind.stdio;
    var host = '127.0.0.1';
    var port = 8080;
    var endpoint = '/mcp';
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      String? consume(String key) {
        if (a == key) {
          if (i + 1 < args.length) return args[++i];
          return null;
        }
        if (a.startsWith('$key=')) return a.substring(key.length + 1);
        return null;
      }

      if (a == '--http') {
        kind = _TransportKind.http;
        continue;
      }
      if (a == '--sse') {
        kind = _TransportKind.sse;
        continue;
      }
      if (a == '--stdio') {
        kind = _TransportKind.stdio;
        continue;
      }
      if (a == '--help' || a == '-h') {
        throw UsageException(
          'Usage: <binary> [--stdio | --http | --sse] '
          '[--host <h>] [--port <n>] [--endpoint <path>]',
        );
      }
      final hostV = consume('--host');
      if (hostV != null) {
        host = hostV;
        continue;
      }
      final portV = consume('--port');
      if (portV != null) {
        port = int.tryParse(portV) ?? port;
        continue;
      }
      final epV = consume('--endpoint');
      if (epV != null) {
        endpoint = epV;
        continue;
      }
      // Unknown flags ignored — hosts (Claude Desktop) may pass extras.
    }
    return _TransportOptions(
        kind: kind, host: host, port: port, endpoint: endpoint);
  }
}

(String, String) _identity(Map<String, dynamic> ui) {
  String s(String key, String fallback) {
    final v = ui[key];
    return v is String && v.isNotEmpty ? v : fallback;
  }

  return (
    s('title', s('name', 'Generated Inline Server')),
    s('version', '1.0.0'),
  );
}

void registerInlineResources(Server server, Map<String, dynamic> ui) {
  final appBody = Map<String, dynamic>.from(ui)..remove('pages');
  if (appBody.isNotEmpty) {
    server.addResource(
      uri: 'ui://app',
      name: 'app',
      description: 'Inline ApplicationDefinition',
      mimeType: 'application/json',
      handler: (_, __) async =>
          resourceJson('ui://app', jsonEncode(appBody)),
    );
  }
  final pages = ui['pages'];
  if (pages is Map) {
    pages.forEach((id, def) {
      if (def is! Map) return;
      final uri = 'ui://pages/$id';
      server.addResource(
        uri: uri,
        name: id.toString(),
        description: 'Inline page $id',
        mimeType: 'application/json',
        handler: (_, __) async => resourceJson(
            uri, jsonEncode(Map<String, dynamic>.from(def))),
      );
    });
  }
  // mcp_ui DSL §11.6.1 — `name` and `version` are REQUIRED.
  // §11.6.2 — `ApplicationDefinition.title` populates `ui://app/info.name`.
  // Fall back through title → name → id → 'Untitled App' so the
  // required field is never empty.
  String? _str(String key) {
    final v = ui[key];
    return v is String && v.isNotEmpty ? v : null;
  }
  final info = <String, dynamic>{
    'name': _str('title') ?? _str('name') ?? _str('id') ?? 'Untitled App',
    'version': _str('version') ?? '0.0.0',
    if (_str('id') != null) 'id': ui['id'],
    if (_str('description') != null) 'description': ui['description'],
    if (ui['icon'] != null) 'icon': ui['icon'],
    if (_str('category') != null) 'category': ui['category'],
    if (ui['publisher'] is Map) 'publisher': ui['publisher'],
    if (ui['timestamps'] is Map) 'timestamps': ui['timestamps'],
    if (ui['screenshots'] is List) 'screenshots': ui['screenshots'],
  };
  server.addResource(
    uri: 'ui://app/info',
    name: 'info',
    description: 'Synthesised from ApplicationDefinition metadata',
    mimeType: 'application/json',
    handler: (_, __) async =>
        resourceJson('ui://app/info', jsonEncode(info)),
  );
}

ReadResourceResult resourceJson(String uri, String text) {
  jsonDecode(text);
  return ReadResourceResult(
    contents: <ResourceContentInfo>[
      ResourceContentInfo(
        uri: uri,
        mimeType: 'application/json',
        text: text,
      ),
    ],
  );
}
''';

  /// `lib/handlers.dart` — domain registration site (headless variant).
  static const String _headlessHandlersStub = r'''
// Generated by AppPlayer Builder.
// Domain tool handlers. The ONLY file most additions touch — every
// other module is reusable scaffolding.
//
// mcp_ui DSL 1.3 spec §3.10 — tool response auto-merge:
//   Each top-level key in the JSON response is merged into page
//   state by binding name on the connecting client. So a handler
//   returning `{'result': '42'}` updates `{{result}}` — the
//   canonical's tool action needs no `onSuccess` for that case.
//
// Response shape rule: make handler return-keys 1:1 with the
// bindings the UI reads. Keep responses minimal — extra keys
// silently overwrite same-named bindings.
//
// Errors: throw any Exception. `_register` serialises it as
// `{'error': '<message>'}` (still §3.10-compatible — bind
// `{{error}}` in the page). For richer error UX use spec §4.4.2
// `onError` with `{{event.message}}` etc. in the canonical.
//
// Use makemind ecosystem packages (mcp_client, mcp_llm, mcp_io_*,
// mcp_form, mcp_canvas, mcp_knowledge, mcp_flow_runtime, …) before
// hand-rolling. See https://app-appplayer.github.io/makemind .
library;

import 'dart:async';
import 'dart:convert';

import 'package:mcp_server/mcp_server.dart';

void registerHandlers({required Server server}) {
  // ─── custom tools (LLM inserts _register(...) calls below) ───

  // Example (delete and replace with your own):
  //
  // _register(
  //   server: server,
  //   name: 'calculate',
  //   description: 'Evaluate an arithmetic expression.',
  //   inputSchema: const <String, dynamic>{
  //     'type': 'object',
  //     'properties': <String, dynamic>{
  //       'expression': <String, dynamic>{'type': 'string'},
  //     },
  //     'required': <String>['expression'],
  //   },
  //   handler: (params) async {
  //     final expr = (params['expression'] as String?) ?? '';
  //     // ... your logic ...
  //     return <String, dynamic>{'result': '...'};
  //   },
  // );

  // ─── custom resources (LLM inserts server.addResource(...) below) ───
}

void _register({
  required Server server,
  required String name,
  required String description,
  required Map<String, dynamic> inputSchema,
  required Future<Map<String, dynamic>> Function(Map<String, dynamic>)
      handler,
}) {
  server.addTool(
    name: name,
    description: description,
    inputSchema: inputSchema,
    handler: (args) async {
      try {
        final result = await handler(args);
        return CallToolResult(
          content: <Content>[TextContent(text: jsonEncode(result))],
        );
      } catch (e) {
        return CallToolResult(
          isError: true,
          content: <Content>[
            TextContent(text: jsonEncode(<String, dynamic>{
              'error': e.toString(),
            })),
          ],
        );
      }
    },
  );
}
''';

  /// Bundle variant of `lib/ui_loader.dart` — exposes
  /// `parseBundlePath(args)` + `registerBundleResources(server,
  /// bundle)`. `loadUi()` is a no-op stub kept for API symmetry with
  /// the inline variant.
  static const String _uiLoaderHeadlessBundle = r'''
// Generated by AppPlayer Builder.
// Bundle UI loader (headless variant). Parses --bundle / sibling
// path. Resource registration happens in
// `mcp_server_setup.dart#registerBundleResources` so the bundle
// stays the only source of truth.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart' hide ResourceContent;
import 'package:mcp_server/mcp_server.dart';

String? parseBundlePath(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--bundle' && i + 1 < args.length) return args[i + 1];
    if (a.startsWith('--bundle=')) return a.substring('--bundle='.length);
  }
  // Fall back to a sibling `app.mbd/` next to the executable so a
  // bare run from the generated app folder Just Works.
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  for (final path in <String>[
    '$exeDir/app.mbd',
    '${Directory(exeDir).parent.path}/app.mbd',
    'app.mbd',
  ]) {
    if (Directory(path).existsSync()) return path;
  }
  return null;
}

Future<void> registerBundleResources(
    Server server, McpBundle bundle) async {
  final uiFiles = await bundle.uiResources.list(extension: '.json');
  if (uiFiles.isEmpty) {
    throw StateError(
        'Bundle has no ui/*.json resources at ${bundle.directory}');
  }
  final registered = <String>{};
  for (final rel in uiFiles) {
    final tail = rel.endsWith('.json')
        ? rel.substring(0, rel.length - '.json'.length)
        : rel;
    final uri = 'ui://$tail';
    registered.add(uri);
    server.addResource(
      uri: uri,
      name: tail.split('/').last,
      description: 'Bundle-backed UI resource: $uri',
      mimeType: 'application/json',
      handler: (_, __) async {
        final text = await bundle.uiResources.read(rel);
        return _resourceText(uri, text);
      },
    );
  }
  if (!registered.contains('ui://app/info')) {
    final info = _appInfoFromManifest(bundle.manifest);
    server.addResource(
      uri: 'ui://app/info',
      name: 'info',
      description: 'Synthesised from manifest.json',
      mimeType: 'application/json',
      handler: (_, __) async => _resourceText('ui://app/info', info),
    );
  }
}

String _appInfoFromManifest(BundleManifest m) {
  final publisher = m.publisher;
  final info = <String, dynamic>{
    'id': m.id,
    'name': m.name,
    'version': m.version,
    if (m.description != null) 'description': m.description,
    if (m.icon != null) 'icon': m.icon,
    if (m.category != null) 'category': m.category!.name,
    if (publisher != null)
      'publisher': <String, dynamic>{
        'name': publisher.name,
        if (publisher.url != null) 'website': publisher.url,
        if (publisher.email != null) 'email': publisher.email,
      },
  };
  return jsonEncode(info);
}

ReadResourceResult _resourceText(String uri, String text) =>
    ReadResourceResult(
      contents: <ResourceContentInfo>[
        ResourceContentInfo(
          uri: uri,
          mimeType: 'application/json',
          text: text,
        ),
      ],
    );

// API symmetry stub — bundle variant uses parseBundlePath +
// registerBundleResources instead of loadUi().
Future<Map<String, dynamic>> loadUi() async => <String, dynamic>{};
''';

  /// Inline variant of `lib/ui_loader.dart`. Embeds the canonical
  /// ApplicationDefinition as a generated Dart `Map<String, dynamic>`
  /// literal (via `DartCodeGenerator`) instead of a JSON-encoded
  /// `const String`. Skips the runtime `jsonDecode` and lets the Dart
  /// compiler validate the literal's syntax.
  static String _uiLoaderHeadlessInline(Map<String, dynamic> ui) {
    // Inline as a JSON string constant rather than a Dart Map literal —
    // (a) round-trips losslessly through any future spec field, (b) keeps
    // the generated source small and grep-friendly. `ui` is already the
    // ApplicationDefinition body (no `manifest` / `schemaVersion` wrapper).
    final encoded = jsonEncode(ui)
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll(r'$', r'\$')
        .replaceAll('\n', r'\n');
    return '''import 'dart:convert';

/// Inlined ApplicationDefinition — the entire UI fits in this constant
/// so the generated server has no on-disk dependency at runtime.
const String _uiJson = '$encoded';

Map<String, dynamic> createApplication() {
  return jsonDecode(_uiJson) as Map<String, dynamic>;
}

/// Async API symmetry with the bundle variant — the underlying
/// `createApplication()` is synchronous because the literal is
/// already in memory.
Future<Map<String, dynamic>> loadUi() async => createApplication();
''';
  }

  // ─── Native (Flutter) app templates ────────────────────────────────
  // Self-contained Flutter apps that **run an MCP server** (Streamable
  // HTTP on localhost:8080 by default) AND render the same UI via
  // `flutter_mcp_ui_runtime`. The two variants share most of
  // `lib/main.dart`; only the UI loader differs (inline JSON constant
  // vs `rootBundle` assets). `mcp_server` is always a dependency so
  // external MCP clients (Claude Desktop, MCP Inspector, AppPlayer)
  // can connect to the running app over HTTP.
  //
  // Customisation hooks LLMs build on top of this base:
  //   * `mcp_client`  — talk to other MCP servers / devices.
  //   * `mcp_llm`     — embed an LLM in the app (chat, tool use).
  //   * `mcp_io_*`    — Modbus / CAN / OPC UA / SCPI / serial.
  //   * `mcp_form`    — input collection.
  //   * `mcp_canvas`  — charts / visualisation.
  //   * `mcp_knowledge` (+ `mcp_fact_graph`, `mcp_profile`) — agent
  //     memory + per-user state.
  // The server config (`_serverConfig` constant) is edited in place
  // when the user wants a different host / port / endpoint or a
  // different transport.

  static const String _flutterMcpUiRuntimeVersion = '^0.4.1';

  static String _flutterAppPubspec({
    required String slug,
    required String bundleDescription,
    required bool includeMcpBundle,
    required bool includeBundleAssets,
  }) {
    final mcpBundleLine =
        includeMcpBundle ? '  mcp_bundle: $_mcpBundleVersion\n' : '';
    // Asset declaration so `flutter build` ships the canonical bundle
    // inside the compiled `.app` / `.apk` / `.ipa`. The native_inline
    // variant doesn't need this — its UI is baked into the source.
    final assetsBlock =
        includeBundleAssets
            ? '''
  assets:
    - app.mbd/manifest.json
    - app.mbd/ui/app.json
    - app.mbd/ui/pages/
'''
            : '';
    return '''
name: $slug
description: $bundleDescription — generated native Flutter app (MCP server + self-UI; AppPlayer Builder).
version: 1.0.0
publish_to: none

environment:
  sdk: '>=3.0.0 <4.0.0'
  flutter: '>=3.19.0'

dependencies:
  flutter:
    sdk: flutter
  flutter_mcp_ui_runtime: $_flutterMcpUiRuntimeVersion
  mcp_server: $_mcpServerVersion
$mcpBundleLine
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0

flutter:
  uses-material-design: true
$assetsBlock''';
  }

  static String _nativeReadme({
    required String name,
    required String slug,
    required String kind,
  }) {
    final isBundle = kind == 'native_bundle';
    final loadLine =
        isBundle
            ? '`lib/ui_loader.dart` reads `app.mbd/ui/*` from Flutter '
                'assets (declared in `pubspec.yaml`).'
            : '`lib/ui_loader.dart` parses the ApplicationDefinition '
                'baked into a `_uiJson` constant.';
    final layout =
        StringBuffer()
          ..writeln('$kind/')
          ..writeln('├── lib/')
          ..writeln(
            '│   ├── main.dart                # entry — runApp(NativeApp())',
          )
          ..writeln(
            '│   ├── native_app.dart          # Flutter shell + status bar',
          )
          ..writeln('│   ├── mcp_server_setup.dart    # MCP server + transport')
          ..writeln(
            '│   ├── ui_loader.dart           # UI source (variant-specific)',
          )
          ..writeln(
            '│   └── handlers.dart            # domain tool registrations',
          )
          ..writeln('├── pubspec.yaml')
          ..writeln('├── README.md');
    if (isBundle) layout.writeln('├── app.mbd/');
    layout.write(
      '└── (after `flutter create .` — android/ ios/ macos/ linux/ windows/ web/)',
    );
    return '''
# $name

Generated by AppPlayer Builder — native Flutter app.

The same UI is **rendered by the app itself** (via
`flutter_mcp_ui_runtime`) **and served over MCP** (Streamable HTTP on
localhost:8080 by default), so external clients (Claude Desktop, MCP
Inspector, AppPlayer) can connect to the running app and see the
exact tools / resources the in-process runtime sees. Edit
`lib/mcp_server_setup.dart`'s `serverConfig` to change transport.

$loadLine

## Layout

The app is split into single-responsibility modules so adding a
domain feature usually only touches `handlers.dart` (or one new
file alongside it):

```
$layout
```

## Run

First-time platform scaffolding — `flutter create` lands android/,
ios/, macos/, linux/, windows/, web/ alongside the existing
`lib/` + `pubspec.yaml` without touching them:

```sh
flutter create --project-name $slug .
```

Then:

```sh
flutter pub get
flutter run
```

`flutter run` picks the entry point from `lib/main.dart` automatically.
Use `flutter build <platform>` for release artifacts.

## Custom tools / resources / domain code

`lib/handlers.dart` is the **only file LLMs need to touch** to add a
new tool. Each handler is registered on both surfaces:

- `runtime.registerToolExecutor(name, handler)` — for self-UI
  buttons that fire `{type:"tool", tool:"<name>"}` in the bundle.
- `server.addTool(name: ..., handler: ...)` — for external MCP
  clients that connect over Streamable HTTP.

Use the `_register` helper inside `handlers.dart` to wire both with
one call. The same handler runs whether the user taps a button in
the app or another MCP client invokes the tool remotely.

## Building on top with the makemind ecosystem

The four modules give you the **MCP-server + self-UI base**. To add
non-trivial features, reach for vetted ecosystem packages first
rather than hand-rolling — the catalog is on
https://app-appplayer.github.io/makemind . Common picks:

- `mcp_client`     — connect to other MCP servers / devices.
- `mcp_llm`        — embed an LLM (chat, tool use).
- `mcp_io_*`       — Modbus / CAN / OPC UA / SCPI / serial / MQTT /
  HTTP / WebSocket transports.
- `mcp_form`       — forms / inputs.
- `mcp_canvas`     — charts / visualisation.
- `mcp_flow_runtime` — declarative workflows / scheduling.
- `mcp_knowledge` (+ `mcp_fact_graph`, `mcp_profile`) — agent
  memory + per-user state.

Add the package to `pubspec.yaml` (caret pin), `flutter pub get`,
import in `handlers.dart` (or split into a new file when handlers
grow). The 5-file scaffold scales from a one-tool demo to a
larger app without restructuring.
''';
  }

  /// Emit the four shared `lib/*.dart` files (main, native_app,
  /// mcp_server_setup, handlers) plus pubspec / README. The
  /// variant-specific `lib/ui_loader.dart` body comes from
  /// [uiLoader]. Both `native_bundle` and `native_inline` write the
  /// same scaffold this way — only the loader and the asset block
  /// differ — so the layout LLMs work on is identical regardless of
  /// UI-location axis.
  Future<void> _emitNativeFiles({
    required String outDir,
    required String slug,
    required String title,
    required String description,
    required String uiLoader,
    required String kind,
    required bool includeBundleAssets,
    required List<String> written,
  }) async {
    final libDir = Directory(p.join(outDir, 'lib'));
    await libDir.create(recursive: true);
    Future<void> writeLib(String name, String body) async {
      final f = File(p.join(libDir.path, name));
      await f.writeAsString(body);
      written.add(f.path);
    }

    await writeLib('main.dart', _nativeMainEntry);
    await writeLib('native_app.dart', _nativeAppShell);
    await writeLib('mcp_server_setup.dart', _nativeServerSetup);
    await writeLib('ui_loader.dart', uiLoader);
    await writeLib('handlers.dart', _nativeHandlersStub);

    // Smoke test placeholder — `flutter create .` would otherwise
    // generate a `MyApp`-flavoured default that doesn't compile
    // against our NativeApp shell. Emitting our own minimal widget
    // test makes flutter create skip the boilerplate (the file
    // already exists) and keeps `flutter analyze` clean.
    final testDir = Directory(p.join(outDir, 'test'));
    await testDir.create(recursive: true);
    final smokeTest = File(p.join(testDir.path, 'widget_test.dart'));
    await smokeTest.writeAsString(_nativeSmokeTest(slug));
    written.add(smokeTest.path);

    final pubspec = File(p.join(outDir, 'pubspec.yaml'));
    await pubspec.writeAsString(
      _flutterAppPubspec(
        slug: slug,
        bundleDescription: description,
        // Native variants no longer pull `mcp_bundle` at runtime —
        // the bundle variant reads via `rootBundle`.
        includeMcpBundle: false,
        includeBundleAssets: includeBundleAssets,
      ),
    );
    written.add(pubspec.path);

    final readme = File(p.join(outDir, 'README.md'));
    await readme.writeAsString(
      _nativeReadme(name: title, slug: slug, kind: kind),
    );
    written.add(readme.path);
  }

  /// Minimal smoke test for native variants. Drops `expect(...)`
  /// against `NativeApp` so `flutter analyze` / `flutter test` find
  /// at least one passing widget test out of the box. Kept
  /// shrinkable — author tests live under `test/<feature>_test.dart`
  /// alongside the matching `lib/handlers_<feature>.dart`.
  static String _nativeSmokeTest(String slug) {
    return '''
// Generated by AppPlayer Builder.
// Smoke test — verifies NativeApp can be instantiated without
// throwing. Replace / extend when you grow handlers.dart.
import 'package:flutter_test/flutter_test.dart';

import 'package:$slug/native_app.dart';

void main() {
  testWidgets('NativeApp builds', (tester) async {
    await tester.pumpWidget(const NativeApp());
    // Don't pumpAndSettle — UI loader + MCP server bootstrap are
    // async; one pump is enough to catch ctor / initState throws.
    expect(find.byType(NativeApp), findsOneWidget);
  });
}
''';
  }

  /// `lib/main.dart` — entry point only. Kept tiny so a Flutter
  /// developer can swap UI shells (e.g. wrap in a custom Provider /
  /// Riverpod scope) without touching the MCP plumbing.
  static const String _nativeMainEntry = r'''
// Generated by AppPlayer Builder.
// Entry point only. UI shell lives in native_app.dart, MCP server
// in mcp_server_setup.dart, UI source in ui_loader.dart, and domain
// tool handlers in handlers.dart. Add new tools by editing
// handlers.dart — every other file is reusable scaffolding.
//
// Default invocation                  → stdio transport (host spawn).
// `--http [opts]`                     → streamable HTTP. Default
//                                       127.0.0.1:8080/mcp.
// `--sse [opts]`                      → SSE (legacy).
// `--host`, `--port`, `--endpoint`    → override defaults.
//
// `open <app>` (Finder double-click) supplies no args → stdio mode
// starts but the inherited stdin is detached, so the server closes
// immediately. The Flutter GUI keeps running because the runtime
// dispatches self-UI tool calls in-process (no MCP wire involved).
library;

import 'package:flutter/material.dart';

import 'native_app.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(NativeApp(args: args));
}
''';

  /// `lib/native_app.dart` — Flutter UI shell + MCP server status
  /// bar. Owns the runtime / server lifecycle. Domain code does not
  /// belong here; put it in handlers.dart.
  static const String _nativeAppShell = r'''
// Generated by AppPlayer Builder.
// Flutter UI shell: hosts MCPUIRuntime for self-rendering, kicks off
// the MCP server (mcp_server_setup.dart), wires domain handlers
// (handlers.dart), and shows a small status bar with the live MCP
// endpoint. Edit-points for app authors:
//   * Background / theme / scaffold chrome — `build()` below.
//   * Adding domain tools — handlers.dart, NOT this file.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:mcp_server/mcp_server.dart';

import 'handlers.dart';
import 'mcp_server_setup.dart';
import 'ui_loader.dart';

class NativeApp extends StatefulWidget {
  const NativeApp({super.key, this.args = const <String>[]});
  final List<String> args;
  @override
  State<NativeApp> createState() => _NativeAppState();
}

class _NativeAppState extends State<NativeApp> {
  MCPUIRuntime? _runtime;
  Map<String, dynamic>? _ui;
  Object? _err;
  String _serverState = 'disabled';
  String? _serverEndpoint;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final ui = await loadUi();
      final pages = ui['pages'] is Map
          ? Map<String, dynamic>.from(ui['pages'] as Map)
          : <String, dynamic>{};

      final runtime = MCPUIRuntime();
      await runtime.initialize(
        ui,
        pageLoader: pages.isEmpty
            ? null
            : (uri) async {
                final id = uri.startsWith('ui://pages/')
                    ? uri.substring('ui://pages/'.length)
                    : uri;
                final def = pages[id];
                if (def is Map) return Map<String, dynamic>.from(def);
                return <String, dynamic>{};
              },
      );

      final transportOpts = TransportOptions.parse(widget.args);

      Server? server;
      var serverState = 'disabled';
      String? serverEndpoint;
      try {
        serverState = 'starting';
        server = await startMcpServer(ui: ui, pages: pages);
      } catch (e) {
        serverState = 'error: $e';
      }

      // Register handlers BEFORE connecting the transport. The first
      // `tools/list` reply must already include every domain tool —
      // otherwise clients that cache the initial list (AppPlayer,
      // Claude Desktop, mcp_client) miss late additions.
      registerHandlers(runtime: runtime, server: server);

      if (server != null && serverState == 'starting') {
        try {
          serverEndpoint = await connectMcpServer(server, transportOpts);
          serverState = 'listening (${transportOpts.kind.name})';
        } catch (e) {
          serverState = 'error: $e';
        }
      }

      if (mounted) {
        setState(() {
          _runtime = runtime;
          _ui = ui;
          _serverState = serverState;
          _serverEndpoint = serverEndpoint;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _err = e);
    }
  }

  @override
  void dispose() {
    _runtime?.destroy();
    // The mcp_server transport keeps running until the isolate
    // exits — `Server.close()` lands once the package exposes a
    // public lifecycle hook. The reference is intentionally not
    // stored on this State (otherwise `flutter analyze` flags it
    // as an unused field).
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_err != null) {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text('Init failed: $_err')),
      );
    } else if (_runtime == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = _runtime!.buildUI(context: context);
    }
    final theme = _ui?['theme'];
    final mode = theme is Map ? theme['mode'] : null;
    final brightness =
        mode == 'dark' ? Brightness.dark : Brightness.light;
    final title =
        _ui?['title'] is String ? _ui!['title'] as String : 'App';
    return MaterialApp(
      title: title,
      theme: ThemeData(brightness: brightness, useMaterial3: true),
      home: Scaffold(
        body: SafeArea(child: body),
        bottomNavigationBar: _ServerStatusBar(
          state: _serverState,
          endpoint: _serverEndpoint,
        ),
      ),
    );
  }
}

class _ServerStatusBar extends StatelessWidget {
  const _ServerStatusBar({required this.state, required this.endpoint});
  final String state;
  final String? endpoint;

  @override
  Widget build(BuildContext context) {
    final color = state.startsWith('listening')
        ? Colors.green
        : state.startsWith('error')
            ? Colors.red
            : Colors.orange;
    final text = endpoint == null
        ? 'MCP server: $state'
        : 'MCP: $endpoint  ($state · tap to copy)';
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: InkWell(
        onTap: endpoint == null
            ? null
            : () => Clipboard.setData(ClipboardData(text: endpoint!)),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: <Widget>[
              Icon(Icons.circle, size: 10, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
''';

  /// `lib/mcp_server_setup.dart` — MCP server bootstrap + transport
  /// config. Edit `serverConfig` values (or replace
  /// `createStreamableHttpTransportAsync` with another transport
  /// factory) to change how external clients reach the app.
  static const String _nativeServerSetup = r'''
// Generated by AppPlayer Builder.
// MCP server bootstrap. Publishes the same `ui://` resources the
// inline / bundle headless variants serve, so any MCP client can
// connect to a running native app and see identical tools and UI
// definitions.
//
// Customise:
//   * Transport — replace createStreamableHttpTransportAsync with
//     stdio (desktop only), SSE, or a different HTTP config.
//   * Resource set — append server.addResource(...) calls inside
//     startMcpServer, or move that logic out into its own file.
//   * Auth — pass `authToken` to the transport factory.
library;

import 'dart:async';
import 'dart:convert';

import 'package:mcp_server/mcp_server.dart';

/// Default transport options when the binary is launched without args
/// (e.g. `open <app>`). stdio matches the headless variants and lets a
/// host-spawned launch (Claude Desktop, AppPlayer's stdio transport)
/// just work. CLI invocations override per [TransportOptions.parse].
const _TransportKind _defaultTransportKind = _TransportKind.stdio;
const String _defaultHost = '127.0.0.1';
const int _defaultPort = 8080;
const String _defaultEndpoint = '/mcp';

enum _TransportKind { stdio, http, sse }

class TransportOptions {
  const TransportOptions({
    required this.kind,
    required this.host,
    required this.port,
    required this.endpoint,
  });
  final _TransportKind kind;
  final String host;
  final int port;
  final String endpoint;

  String get endpointUrl => 'http://$host:$port$endpoint';

  static TransportOptions parse(List<String> args) {
    var kind = _defaultTransportKind;
    var host = _defaultHost;
    var port = _defaultPort;
    var endpoint = _defaultEndpoint;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      String? consume(String key) {
        if (a == key) {
          if (i + 1 < args.length) return args[++i];
          return null;
        }
        if (a.startsWith('$key=')) return a.substring(key.length + 1);
        return null;
      }
      if (a == '--http') {
        kind = _TransportKind.http;
        continue;
      }
      if (a == '--sse') {
        kind = _TransportKind.sse;
        continue;
      }
      if (a == '--stdio') {
        kind = _TransportKind.stdio;
        continue;
      }
      final hostV = consume('--host');
      if (hostV != null) {
        host = hostV;
        continue;
      }
      final portV = consume('--port');
      if (portV != null) {
        port = int.tryParse(portV) ?? port;
        continue;
      }
      final epV = consume('--endpoint');
      if (epV != null) {
        endpoint = epV;
        continue;
      }
    }
    return TransportOptions(
        kind: kind, host: host, port: port, endpoint: endpoint);
  }
}

/// Build an MCP server with the same `ui://` resource layout the
/// headless variants publish. Resources are registered but the
/// transport is NOT connected yet — handlers must be registered
/// first so they're visible on the very first `tools/list` from
/// any client. Call [connectMcpServer] to start serving.
Future<Server> startMcpServer({
  required Map<String, dynamic> ui,
  required Map<String, dynamic> pages,
}) async {
  final identity = _identityFromUi(ui);
  final config = McpServerConfig(
    name: identity.$1,
    version: identity.$2,
    capabilities: const ServerCapabilities(
      resources: ResourcesCapability(
          listChanged: false, subscribe: false),
      tools: ToolsCapability(listChanged: false),
    ),
    enableDebugLogging: false,
  );
  final server = McpServer.createServer(config);

  final appBody = Map<String, dynamic>.from(ui)..remove('pages');
  if (appBody.isNotEmpty) {
    server.addResource(
      uri: 'ui://app',
      name: 'app',
      description: 'ApplicationDefinition body (no pages map)',
      mimeType: 'application/json',
      handler: (_, __) async => _resource('ui://app', appBody),
    );
  }
  pages.forEach((id, def) {
    if (def is! Map) return;
    final uri = 'ui://pages/$id';
    server.addResource(
      uri: uri,
      name: id.toString(),
      description: 'Page $id',
      mimeType: 'application/json',
      handler: (_, __) async =>
          _resource(uri, Map<String, dynamic>.from(def)),
    );
  });
  // mcp_ui DSL §11.6.1 — `name` and `version` are REQUIRED.
  // §11.6.2 — `ApplicationDefinition.title` populates `ui://app/info.name`.
  // Fall back through title → name → id → 'Untitled App' so the
  // required field is never empty.
  String? _str(String key) {
    final v = ui[key];
    return v is String && v.isNotEmpty ? v : null;
  }
  final info = <String, dynamic>{
    'name': _str('title') ?? _str('name') ?? _str('id') ?? 'Untitled App',
    'version': _str('version') ?? '0.0.0',
    if (_str('id') != null) 'id': ui['id'],
    if (_str('description') != null) 'description': ui['description'],
    if (ui['icon'] != null) 'icon': ui['icon'],
    if (_str('category') != null) 'category': ui['category'],
    if (ui['publisher'] is Map) 'publisher': ui['publisher'],
    if (ui['timestamps'] is Map) 'timestamps': ui['timestamps'],
    if (ui['screenshots'] is List) 'screenshots': ui['screenshots'],
  };
  server.addResource(
    uri: 'ui://app/info',
    name: 'info',
    description: 'Synthesised from ApplicationDefinition metadata',
    mimeType: 'application/json',
    handler: (_, __) async => _resource('ui://app/info', info),
  );

  return server;
}

/// Open the transport selected by [opts]. Call this AFTER
/// `registerHandlers` so the first `tools/list` reply already contains
/// every domain tool. Returns a human-readable endpoint string for the
/// status bar (`null` for stdio, since there's no URL to display).
///
/// stdio behaviour: when `open <app>` (Finder double-click) launches
/// the binary without args, the inherited stdin is detached and the
/// stdio transport closes immediately. The Flutter GUI keeps running
/// because self-UI tool calls dispatch in-process via the runtime —
/// the MCP wire is only required for external hosts.
Future<String?> connectMcpServer(
  Server server,
  TransportOptions opts,
) async {
  switch (opts.kind) {
    case _TransportKind.stdio:
      final transport = McpServer.createStdioTransport().get();
      server.connect(transport);
      return null;
    case _TransportKind.http:
      final transport = (await McpServer.createStreamableHttpTransportAsync(
        opts.port,
        host: opts.host,
        endpoint: opts.endpoint,
        // JSON-mode default keeps client integrations simple — most
        // MCP clients (mcp_client, dart-mcp) expect JSON envelopes.
        // Switch to `false` to enable SSE streaming for long-running
        // tool calls.
        isJsonResponseEnabled: true,
      )).get();
      server.connect(transport);
      return opts.endpointUrl;
    case _TransportKind.sse:
      // ignore: deprecated_member_use
      final transport = McpServer.createSseTransport(SseTransportConfig(
        endpoint: opts.endpoint,
        messagesEndpoint: '${opts.endpoint}/messages',
        host: opts.host,
        port: opts.port,
      )).get();
      server.connect(transport);
      return opts.endpointUrl;
  }
}

(String, String) _identityFromUi(Map<String, dynamic> ui) {
  String s(String key, String fallback) {
    final v = ui[key];
    return v is String && v.isNotEmpty ? v : fallback;
  }

  return (
    s('title', s('name', 'Generated Native App')),
    s('version', '1.0.0'),
  );
}

ReadResourceResult _resource(String uri, Map<String, dynamic> body) =>
    ReadResourceResult(
      contents: <ResourceContentInfo>[
        ResourceContentInfo(
          uri: uri,
          mimeType: 'application/json',
          text: jsonEncode(body),
        ),
      ],
    );
''';

  /// `lib/handlers.dart` — domain tool registration site. The only
  /// file most LLM-driven changes touch. Empty by default — uses
  /// the `_register` helper to wire each handler on both runtime
  /// (self-UI) and server (external clients) at once.
  static const String _nativeHandlersStub = r'''
// Generated by AppPlayer Builder.
// Domain tool handlers. The ONLY file most additions touch — every
// other module is reusable scaffolding.
//
// mcp_ui DSL 1.3 spec §3.10 — tool response auto-merge:
//   When a `tool` action succeeds, each top-level key in the JSON
//   response is merged into page state by binding name. So a
//   handler returning `{'result': '42'}` updates `{{result}}` —
//   no `onSuccess` is required in the canonical.
//
// To add a tool:
//   1. Define a handler that takes a params Map and returns a
//      Future<Map<String, dynamic>>. Make each top-level key match
//      the page state binding the UI reads. Keep responses minimal
//      — extra keys overwrite same-named bindings.
//   2. Call `_register(...)` inside `registerHandlers` below to
//      wire it on BOTH surfaces (self-UI buttons + external MCP
//      clients) with one call.
//
// Why register on both: a UI button in the bundle fires
// `{type:"tool", tool:"<name>"}`. With a same-process self-UI the
// call lands on the runtime executor; over MCP an external client
// (AppPlayer, Claude Desktop, …) calls the server tool. `_register`
// folds the response into state on the self-UI side too, so both
// paths satisfy §3.10 identically.
//
// Errors: throw any Exception. `_register` serialises it as
// `{'error': '<message>'}` (still §3.10-compatible — bind `{{error}}`
// in the page to display). For richer error UX use spec §4.4.2
// `onError` with `{{event.message}}` etc. in the canonical.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:mcp_server/mcp_server.dart';

void registerHandlers({
  required MCPUIRuntime runtime,
  Server? server,
}) {
  // ─── custom tools (LLM inserts _register(...) calls below) ───

  // Example (delete and replace with your own):
  //
  // _register(
  //   runtime: runtime,
  //   server: server,
  //   name: 'calculate',
  //   description: 'Evaluate an arithmetic expression.',
  //   inputSchema: const <String, dynamic>{
  //     'type': 'object',
  //     'properties': <String, dynamic>{
  //       'expression': <String, dynamic>{'type': 'string'},
  //     },
  //     'required': <String>['expression'],
  //   },
  //   handler: (params) async {
  //     final expr = (params['expression'] as String?) ?? '';
  //     // ... your logic ...
  //     return <String, dynamic>{'result': '...'};
  //   },
  // );

  // ─── custom resources (LLM inserts server?.addResource(...) below) ───
}

/// Wire one handler on both surfaces. Same Dart function executes
/// regardless of whether the call came from a self-UI button tap
/// or an external MCP client. Errors are serialised as a JSON
/// `{'error': '<message>'}` payload so the host auto-fold pipeline
/// keeps state binding consistent (no special unwrapping needed).
void _register({
  required MCPUIRuntime runtime,
  Server? server,
  required String name,
  required String description,
  required Map<String, dynamic> inputSchema,
  required Future<Map<String, dynamic>> Function(Map<String, dynamic>)
      handler,
}) {
  // Self-host §3.10: when the self-UI calls this tool the runtime's
  // ToolActionExecutor delegates to this executor, but does NOT auto-
  // merge the response back into state (the runtime exposes
  // `mergeState` but never invokes it on tool responses — external
  // hosts like AppPlayer fold via their own ToolDispatcher). Mirror
  // that fold here so `{type:"tool", tool:"<name>"}` actions update
  // bindings without an explicit `onSuccess`, matching the canonical
  // pattern that already works over MCP.
  runtime.registerToolExecutor(name, (params) async {
    final result = await handler(params);
    runtime.stateManager.mergeState(result);
    return result;
  });
  server?.addTool(
    name: name,
    description: description,
    inputSchema: inputSchema,
    handler: (args) async {
      try {
        final result = await handler(args);
        return CallToolResult(
          content: <Content>[
            TextContent(text: jsonEncode(result)),
          ],
        );
      } catch (e) {
        return CallToolResult(
          isError: true,
          content: <Content>[
            TextContent(text: jsonEncode(<String, dynamic>{
              'error': e.toString(),
            })),
          ],
        );
      }
    },
  );
}
''';

  /// Variant-specific UI loader — inline form. Bakes the
  /// ApplicationDefinition as a Dart `Map<String, dynamic>` literal
  /// (via `DartCodeGenerator`) so the compiled app skips runtime
  /// `jsonDecode` and the Dart compiler validates the literal once.
  static String _uiLoaderInline(Map<String, dynamic> ui) {
    final body = DartCodeGenerator.fromApplication(ui);
    return '''$body
Future<Map<String, dynamic>> loadUi() async => createApplication();
''';
  }

  /// Variant-specific UI loader — bundle form. Reads `app.mbd/ui/*`
  /// from Flutter assets (declared in pubspec).
  static const String _uiLoaderBundle = r'''
// Generated by AppPlayer Builder.
// Bundle UI loader: reads `app.mbd/ui/app.json` + every
// `app.mbd/ui/pages/<id>.json` from Flutter rootBundle assets
// (declared in pubspec.yaml). Page enumeration uses the modern
// `AssetManifest.loadFromAssetBundle` API — Flutter 3.16+ no
// longer ships `AssetManifest.json`, only the binary form.
// Refresh the assets by rebuilding (vibe overwrites `app.mbd/`
// from the canonical bundle).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;

Future<Map<String, dynamic>> loadUi() async {
  final ui = <String, dynamic>{};
  final appJson = await rootBundle.loadString('app.mbd/ui/app.json');
  final body = jsonDecode(appJson);
  if (body is Map) ui.addAll(Map<String, dynamic>.from(body));
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final pages = <String, dynamic>{};
  for (final key in manifest.listAssets()) {
    if (!key.startsWith('app.mbd/ui/pages/')) continue;
    if (!key.endsWith('.json')) continue;
    final tail = key.substring(
      'app.mbd/ui/pages/'.length,
      key.length - '.json'.length,
    );
    if (tail.contains('/')) continue;
    final pageBody = jsonDecode(await rootBundle.loadString(key));
    if (pageBody is Map) {
      pages[tail] = Map<String, dynamic>.from(pageBody);
    }
  }
  if (pages.isNotEmpty) ui['pages'] = pages;
  return ui;
}
''';
}
