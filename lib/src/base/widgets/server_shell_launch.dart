/// "Cloud Server" debug-variant launcher — prepares a cloud server app
/// bundle for a LOCAL run of the REAL marketplace serving shell and
/// describes how to spawn it.
///
/// The marketplace runs a `type: "server"` bundle as: Node shell
/// (`lib/index.js`) + the packed bundle (`BUNDLE_PATH`) + the bundle's
/// TypeScript tools compiled to JS (`TOOLS_DIR`), all configured via
/// environment variables. Verifying "will my bundle actually serve?"
/// therefore means running that exact shell — NOT a re-implementation —
/// against the exact artifacts the studio packs. This module reproduces
/// the provision pipeline locally:
///
///   1. pack the project's serving bundle → `build/server/<name>.mcpb`
///      (canonical packer — same artifact the publisher uploads),
///   2. compile `tools/*.ts` → `build/server/tools_out/` (`npx tsc`,
///      mirroring the platform's `npm ci && tsc` build step),
///   3. describe the spawn: `node <shell>/lib/index.js` with
///      `BUNDLE_PATH` / `TOOLS_DIR` / `PORT` / `SERVER_AUTH_MODE=open`
///      (open auth — a local debug loop; the deployed listing gets its
///      per-instance key from provisioning).
///
/// The shell location comes from `VibeSettings.serverShellPath` (interim
/// hand-edited key; the marketplace `mcp-serve` CLI will supersede it).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../boot/claude_cli_resolver.dart' show resolveCliExecutable;
import '../install/bundle_pack.dart';

/// Everything the inspector session needs to spawn the local shell.
class ServerShellLaunch {
  const ServerShellLaunch({
    required this.nodeBinary,
    required this.indexJs,
    required this.environment,
    required this.port,
    required this.mcpbPath,
  });

  final String nodeBinary;
  final String indexJs;
  final Map<String, String> environment;
  final int port;
  final String mcpbPath;
}

/// Raised with a user-presentable message when preparation cannot
/// proceed (missing config, missing toolchain, compile failure, …).
class ServerShellLaunchException implements Exception {
  ServerShellLaunchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Base local debug port for the shell (distinct from the studio's own
/// 78xx band and the vibe binaries' 8080 default). The launcher scans
/// upward from here for a FREE port — a fixed port turns any orphaned
/// shell (e.g. left behind by a studio crash/restart, which does not
/// reap child processes) into an EADDRINUSE death of the new shell
/// while the client silently connects to the stale one (wrong bundle,
/// card stuck on error).
const int kServerShellDebugPort = 8931;

/// Find the first free port in `[base, base+span)`; falls back to the
/// base when every candidate is busy (the spawn will then surface the
/// bind error loudly instead of connecting to a stale shell).
///
/// The probe MUST match how the Node shell binds — a dual-stack IPv6
/// wildcard (`*:port`). Probing only the IPv4 loopback reports "free"
/// while an orphaned shell still holds the IPv6 wildcard: the fresh
/// shell then dies with EADDRINUSE a beat after spawn (card flips to
/// error) while the client silently connects to the stale orphan via
/// the IPv4-mapped route — exactly the wrong-bundle trap this scan
/// exists to prevent. So a port counts as free only when the IPv6
/// any-address bind (v6Only:false = dual-stack, Node's default)
/// succeeds too.
Future<int> _findFreePort(int base, {int span = 20}) async {
  for (var port = base; port < base + span; port++) {
    try {
      final v4 = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      await v4.close();
      final v6 = await ServerSocket.bind(
        InternetAddress.anyIPv6,
        port,
        v6Only: false,
      );
      await v6.close();
      return port;
    } catch (_) {
      continue; // busy on either stack — try the next one
    }
  }
  return base;
}

/// Read the project kind name (`appPlayerApp` / `studioPackage` /
/// `cloudServerApp`) off `project.apbproj`. Null when unreadable —
/// callers fall back to the app-player default. Drives kind-scoped
/// surfaces (the debug panel shows only the variants that APPLY to the
/// project: a cloud server app never converts to Dart/Flutter, an app
/// project never boots the serving shell).
String? projectKindNameOf(String projectPath) {
  try {
    final metaFile = File(p.join(projectPath, 'project.apbproj'));
    if (!metaFile.existsSync()) return null;
    final meta = jsonDecode(metaFile.readAsStringSync());
    if (meta is! Map<String, dynamic>) return null;
    final kind = meta['kind'];
    return kind is String && kind.isNotEmpty ? kind : null;
  } catch (_) {
    return null;
  }
}

/// Read `project.apbproj` and resolve the active serving bundle dir.
/// Returns null when the project meta or channel cannot be resolved.
String? servingBundleDirOf(String projectPath) {
  try {
    final metaFile = File(p.join(projectPath, 'project.apbproj'));
    if (!metaFile.existsSync()) return null;
    final meta = jsonDecode(metaFile.readAsStringSync());
    if (meta is! Map<String, dynamic>) return null;
    final channels = meta['channels'];
    if (channels is! Map) return null;
    final active = (meta['activeChannel'] as String?) ?? 'serving';
    final ch = (channels[active] ?? channels['serving']) as Map?;
    final subdir = ch?['subdir'] as String?;
    if (subdir == null || subdir.isEmpty) return null;
    final dir = p.join(projectPath, subdir);
    return Directory(dir).existsSync() ? dir : null;
  } catch (_) {
    return null;
  }
}

/// True when the bundle at [bundleDir] is a cloud server app
/// (`manifest.type == "server"`). Drives the variant card's visibility.
bool isServerBundleDir(String bundleDir) {
  try {
    final f = File(p.join(bundleDir, 'manifest.json'));
    if (!f.existsSync()) return false;
    final doc = jsonDecode(f.readAsStringSync());
    final manifest = (doc as Map<String, dynamic>)['manifest'];
    return manifest is Map<String, dynamic> && manifest['type'] == 'server';
  } catch (_) {
    return false;
  }
}

/// Prepare artifacts + spawn description for the local shell run.
///
/// Throws [ServerShellLaunchException] with an actionable message on any
/// unmet precondition. Heavy steps (pack, tsc) run on every call — they
/// are cheap at bundle scale and guarantee the debug run always serves
/// the CURRENT sources (no stale-artifact confusion).
Future<ServerShellLaunch> prepareServerShellLaunch({
  required String projectPath,
  required String? serverShellPath,
  int? port,
}) async {
  port ??= await _findFreePort(kServerShellDebugPort);
  // ── Preconditions ────────────────────────────────────────────────
  final bundleDir = servingBundleDirOf(projectPath);
  if (bundleDir == null) {
    throw ServerShellLaunchException(
      'No serving bundle found under the project.',
    );
  }
  if (!isServerBundleDir(bundleDir)) {
    throw ServerShellLaunchException(
      'The serving bundle is not a cloud server app '
      '(manifest.type != "server").',
    );
  }
  if (serverShellPath == null || serverShellPath.isEmpty) {
    throw ServerShellLaunchException(
      'Set `serverShellPath` in settings.json — the marketplace '
      'serving-shell directory (contains lib/index.js).',
    );
  }
  final indexJs = p.join(serverShellPath, 'lib', 'index.js');
  if (!File(indexJs).existsSync()) {
    throw ServerShellLaunchException(
      'Serving shell not built: $indexJs not found '
      '(run `npm run build` in the shell directory).',
    );
  }
  final node = resolveCliExecutable('node');
  if (node == null) {
    throw ServerShellLaunchException(
      'node executable not found on PATH.',
    );
  }

  // ── ① Pack (canonical packer — the exact publish artifact) ───────
  final outDir = Directory(p.join(projectPath, 'build', 'server'));
  await outDir.create(recursive: true);
  final mcpbPath = p.join(outDir.path, '${p.basename(projectPath)}.mcpb');
  final bytes = await packBundleDirForDistribution(bundleDir);
  await File(mcpbPath).writeAsBytes(bytes, flush: true);

  // ── ② Compile tools/*.ts (mirrors the platform's npm ci && tsc) ──
  final env = <String, String>{
    'BUNDLE_PATH': mcpbPath,
    'PORT': '$port',
    // Local debug loop — no key gate. The deployed listing's key comes
    // from provisioning; keyed local runs additionally need the kernel
    // client to forward accessToken headers.
    'SERVER_AUTH_MODE': 'open',
  };
  final toolsDir = Directory(p.join(bundleDir, 'tools'));
  final tsFiles =
      toolsDir.existsSync()
          ? toolsDir
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((f) => f.path.endsWith('.ts'))
              .map((f) => f.path)
              .toList()
          : const <String>[];
  if (tsFiles.isNotEmpty) {
    final npx = resolveCliExecutable('npx');
    if (npx == null) {
      throw ServerShellLaunchException(
        'npx executable not found on PATH (needed to compile '
        'tools/*.ts).',
      );
    }
    final toolsOut = p.join(outDir.path, 'tools_out');
    final result = await Process.run(npx, <String>[
      '-y',
      '-p',
      'typescript',
      'tsc',
      ...tsFiles,
      '--outDir',
      toolsOut,
      '--module',
      'commonjs',
      '--target',
      'es2020',
      '--esModuleInterop',
      '--skipLibCheck',
    ]);
    if (result.exitCode != 0) {
      throw ServerShellLaunchException(
        'tools/*.ts compile failed:\n${result.stdout}${result.stderr}',
      );
    }
    env['TOOLS_DIR'] = toolsOut;
  }

  return ServerShellLaunch(
    nodeBinary: node,
    indexJs: indexJs,
    environment: env,
    port: port,
    mcpbPath: mcpbPath,
  );
}
