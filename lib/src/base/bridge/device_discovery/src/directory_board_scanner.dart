// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/device_discovery/lib/src/directory_board_scanner.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
import 'dart:async';

import 'package:dartdap/dartdap.dart' as ldap;

/// Directory-based discovery (`specs/platform/17-device-discovery.md` §2 —
/// the `ldap` source): an organization's directory (company, school,
/// church, home server — any LDAP v3 directory) lists its MCP servers as
/// entries carrying the standard `labeledURI` attribute (RFC 2079). The
/// URI is the endpoint and follows the same URL-scheme identity as every
/// other registration path: `http(s)://` = streamableHttp, `tcp://` =
/// newline-JSON board.
///
/// Stage 1 here is a directory search, not a radio scan; Stage 2 is the
/// same probe-confirm every other source uses.
class DirectoryConfig {
  const DirectoryConfig({
    required this.host,
    this.port,
    this.ssl = false,
    this.bindDN,
    this.password,
    required this.baseDN,
  });

  final String host;

  /// Defaults to 636 when [ssl], 389 otherwise.
  final int? port;
  final bool ssl;

  /// Anonymous bind when null.
  final String? bindDN;
  final String? password;
  final String baseDN;

  int get effectivePort => port ?? (ssl ? 636 : 389);

  Map<String, Object?> toJson() => {
        'host': host,
        if (port != null) 'port': port,
        'ssl': ssl,
        if (bindDN != null) 'bindDN': bindDN,
        if (password != null) 'password': password,
        'baseDN': baseDN,
      };

  static DirectoryConfig? fromJson(Map<String, Object?> json) {
    final host = json['host'];
    final baseDN = json['baseDN'];
    if (host is! String || host.isEmpty) return null;
    if (baseDN is! String || baseDN.isEmpty) return null;
    return DirectoryConfig(
      host: host,
      port: json['port'] as int?,
      ssl: json['ssl'] as bool? ?? false,
      bindDN: json['bindDN'] as String?,
      password: json['password'] as String?,
      baseDN: baseDN,
    );
  }
}

/// One directory entry that names an MCP endpoint.
class DirectoryBoardCandidate {
  const DirectoryBoardCandidate({required this.endpoint, required this.name});

  /// Endpoint URL from `labeledURI` (label stripped).
  final String endpoint;

  /// Display name (`cn`, falling back to the endpoint).
  final String name;

  @override
  String toString() => 'DirectoryBoardCandidate($endpoint, "$name")';
}

/// RFC 2079 `labeledURI` = `<URI> [<label>]` — returns the URI token, or
/// null when the value is empty.
String? parseLabeledUri(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final space = trimmed.indexOf(' ');
  return space == -1 ? trimmed : trimmed.substring(0, space);
}

/// One raw directory entry: attribute name → values. The scanner only
/// looks at `labeledURI` and `cn`.
typedef DirectoryEntry = Map<String, List<String>>;

/// Searches the configured directory for entries with a `labeledURI`.
/// The LDAP wire interaction is injectable so hosts and tests can fake
/// the directory; the default implementation uses dartdap (BSD-2-Clause).
class DirectoryBoardScanner {
  DirectoryBoardScanner({
    Future<List<DirectoryEntry>> Function(DirectoryConfig config)? search,
  }) : _search = search ?? _ldapSearch;

  final Future<List<DirectoryEntry>> Function(DirectoryConfig config) _search;

  Stream<DirectoryBoardCandidate> scan(DirectoryConfig config) async* {
    final entries = await _search(config);
    for (final entry in entries) {
      final uris = entry['labeledURI'] ?? const <String>[];
      final cn = entry['cn'] ?? const <String>[];
      for (final raw in uris) {
        final endpoint = parseLabeledUri(raw);
        if (endpoint == null) continue;
        yield DirectoryBoardCandidate(
          endpoint: endpoint,
          name: cn.isNotEmpty ? cn.first : endpoint,
        );
      }
    }
  }

  static Future<List<DirectoryEntry>> _ldapSearch(
    DirectoryConfig config,
  ) async {
    final connection = ldap.LdapConnection(
      host: config.host,
      port: config.effectivePort,
      ssl: config.ssl,
      bindDN: config.bindDN == null ? null : ldap.DN(config.bindDN!),
      password: config.password ?? '',
    );
    try {
      await connection.open();
      if (config.bindDN != null && config.bindDN!.isNotEmpty) {
        await connection.bind();
      }
      final result = await connection.search(
        ldap.DN(config.baseDN),
        ldap.Filter.present('labeledURI'),
        const ['labeledURI', 'cn'],
      );
      final entries = <DirectoryEntry>[];
      await for (final entry in result.stream) {
        final map = <String, List<String>>{};
        entry.attributes.forEach((name, attribute) {
          map[name] =
              attribute.values.map((v) => v.toString()).toList(growable: false);
        });
        entries.add(map);
      }
      return entries;
    } finally {
      try {
        await connection.close();
      } catch (_) {
        // Connection may already be gone.
      }
    }
  }
}
