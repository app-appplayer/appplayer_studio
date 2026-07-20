import 'dart:io';

/// Resolves an allowlisted CLI (`dart`, `flutter`, `pub`, `git`, `claude`, …)
/// to a launchable absolute path.
///
/// A desktop app started from Finder / `open` / the Dock inherits only the
/// minimal launchd PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). Binaries installed
/// through nvm / npm-global / Homebrew / fvm / asdf are therefore NOT on that
/// PATH, so spawning a bare name (`claude`, `dart`, `flutter`, …) fails with
/// ENOENT. Two consumers hit this:
///   - the Claude Code subscription LLM provider (spawns `claude`), and
///   - the `build.run_shell` tool the LLM uses to run `dart` / `flutter`
///     during a headless build (`dart pub get`, `dart compile exe`, …).
///
/// Resolution order:
///   1. an explicit, existing configured path,
///   2. the login shell's own PATH lookup (`command -v <name>`) — this is
///      what picks up nvm / Homebrew / fvm / asdf / user-local installs,
///   3. well-known install locations,
///   4. null (caller decides the fallback — the CLI helpers below fall back
///      to the bare name so a terminal-launched process still works).
String? resolveCliExecutable(String name, {String? configured}) {
  if (_isUsable(configured)) return configured;
  final cached = _cache[name];
  if (cached != null) return cached;
  final resolved = _resolveFresh(name);
  if (resolved != null) _cache[name] = resolved;
  return resolved;
}

/// Claude Code CLI — always returns a string (bare `claude` as last resort so
/// the provider gets a spawnable value even when discovery fails).
String resolveClaudeCli([String? configured]) =>
    resolveCliExecutable('claude', configured: configured) ?? 'claude';

final Map<String, String> _cache = <String, String>{};

bool _isUsable(String? path) =>
    path != null &&
    path.isNotEmpty &&
    !path.contains('://') &&
    File(path).existsSync();

String? _resolveFresh(String name) {
  // Login shell resolves the interactive PATH (nvm / Homebrew / fvm / asdf /
  // user local) that launchd does not hand a GUI app.
  final probe = 'command -v ${_shellSingleQuote(name)}';
  for (final shell in const <String>['/bin/zsh', '/bin/bash']) {
    if (!File(shell).existsSync()) continue;
    try {
      final r = Process.runSync(shell, <String>['-lc', probe]);
      if (r.exitCode == 0) {
        final out = (r.stdout as String).trim();
        if (_isUsable(out)) return out;
      }
    } catch (_) {
      // try the next shell
    }
  }

  final home = Platform.environment['HOME'] ?? '';
  for (final dir in <String>[
    '/opt/homebrew/bin',
    '/usr/local/bin',
    if (home.isNotEmpty) '$home/.local/bin',
    if (home.isNotEmpty) '$home/sdk/flutter/bin',
    if (home.isNotEmpty) '$home/fvm/default/bin',
    if (home.isNotEmpty) '$home/.pub-cache/bin',
  ]) {
    final candidate = '$dir/$name';
    if (_isUsable(candidate)) return candidate;
  }
  // Tool-specific well-known spots the generic dir sweep above misses.
  if (name == 'claude' && home.isNotEmpty) {
    const claudeLocal = '/.claude/local/claude';
    if (_isUsable('$home$claudeLocal')) return '$home$claudeLocal';
  }

  return null;
}

String _shellSingleQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";
