/// Durable registry + keychain vault for locally-added MCP servers.
///
/// A "local server" is an MCP endpoint the user connects to directly — over
/// Streamable HTTP / SSE (a URL, possibly externally exposed so it can carry a
/// bearer token) or stdio (a local executable). Connections are in-memory, so
/// the transport + address + display name persist here (a plain JSON file
/// under the config root) and the access token — a secret — lives in the OS
/// keychain vault, the record keeping only a `credentialRef`
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_secure/appplayer_secure.dart' show SecureStorage;
import 'package:brain_kernel/brain_kernel.dart' show KernelTransportKind;
import 'package:path/path.dart' as p;

/// One locally-added server. [id] is the stable identity (also the kernel
/// connection id + store key): the endpoint for HTTP/SSE, the command for
/// stdio. [credentialRef] is the keychain key holding the access token (HTTP
/// only), or null.
class LocalServerRecord {
  const LocalServerRecord({
    required this.id,
    required this.transport,
    required this.name,
    this.endpoint,
    this.command,
    this.args = const <String>[],
    this.credentialRef,
  });

  final String id;
  final KernelTransportKind transport;
  final String name;

  /// HTTP / SSE target URL (null for stdio).
  final String? endpoint;

  /// stdio executable (null for HTTP / SSE).
  final String? command;

  /// stdio launch arguments.
  final List<String> args;

  final String? credentialRef;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'transport': transport.name,
    'name': name,
    if (endpoint != null) 'endpoint': endpoint,
    if (command != null) 'command': command,
    if (args.isNotEmpty) 'args': args,
    if (credentialRef != null) 'credentialRef': credentialRef,
  };

  static LocalServerRecord fromJson(Map<String, dynamic> j) =>
      LocalServerRecord(
        id: j['id'] as String,
        transport: KernelTransportKind.values.firstWhere(
          (t) => t.name == j['transport'],
          orElse: () => KernelTransportKind.streamableHttp,
        ),
        name: (j['name'] as String?) ?? j['id'] as String,
        endpoint: j['endpoint'] as String?,
        command: j['command'] as String?,
        args: (j['args'] as List?)?.cast<String>() ?? const <String>[],
        credentialRef: j['credentialRef'] as String?,
      );
}

/// Durable JSON-file registry of local servers, keyed by [LocalServerRecord.id].
/// [onChanged] fires after any mutation so the host can refresh the Home grid.
class LocalServerStore {
  LocalServerStore(String configRoot)
    : _file = File(p.join(configRoot, 'local_servers.json'));

  final File _file;

  /// Called after add/remove so the Home INSTALLED APPS grid refreshes.
  void Function()? onChanged;

  Map<String, LocalServerRecord> _read() {
    if (!_file.existsSync()) return <String, LocalServerRecord>{};
    try {
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map<String, dynamic>)
        return <String, LocalServerRecord>{};
      final out = <String, LocalServerRecord>{};
      decoded.forEach((k, v) {
        if (v is Map<String, dynamic>) out[k] = LocalServerRecord.fromJson(v);
      });
      return out;
    } catch (_) {
      return <String, LocalServerRecord>{};
    }
  }

  void _write(Map<String, LocalServerRecord> map) {
    final json = <String, dynamic>{
      for (final e in map.entries) e.key: e.value.toJson(),
    };
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(jsonEncode(json));
    onChanged?.call();
  }

  List<LocalServerRecord> list() => _read().values.toList(growable: false);

  LocalServerRecord? get(String id) => _read()[id];

  /// Insert or overwrite the record for its id.
  void put(LocalServerRecord record) {
    final map = _read();
    map[record.id] = record;
    _write(map);
  }

  void remove(String id) {
    final map = _read();
    if (map.remove(id) != null) _write(map);
  }
}

/// Keychain-backed store for local-server access tokens: the token
/// is a secret, so it lives in the OS keychain under a dedicated namespace,
/// never in the plaintext [LocalServerStore] (which keeps only a
/// `credentialRef`). Keyed by the server id.
class LocalServerCredentialVault {
  LocalServerCredentialVault(this._storage);

  static const String namespace = 'local.server';

  final SecureStorage _storage;

  /// The keychain key (and the record's `credentialRef`) for [id].
  static String refFor(String id) => id;

  Future<void> write(String ref, String secret) =>
      _storage.write(ref, secret, namespace: namespace);

  Future<String?> read(String ref) => _storage.read(ref, namespace: namespace);

  Future<void> delete(String ref) => _storage.delete(ref, namespace: namespace);
}
