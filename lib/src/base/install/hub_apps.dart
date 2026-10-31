/// The apps a person registered on a hub, each with a hub token of its own
/// (platform spec 15 §6 · §10.2).
///
/// A hub token names which server it opens and who may come in, so two apps on
/// the same hub carry two tokens. The hub lets a token holder in without a
/// market login (`POST <hub.control>/hub/sessions`); this host keeps the app's
/// name and the token's id in one list and the token itself in the keychain.
library;

import 'dart:convert';

import 'package:appplayer_secure/appplayer_secure.dart' show SecureStorage;
import 'package:http/http.dart' as http;

import 'hub_connections.dart' show HubGrant;

/// Keychain namespace of the app list (names and ids, no secrets).
const String kHubAppsNamespace = 'hub.apps';

/// Keychain namespace of the app tokens (one per app).
const String kHubAppTokenNamespace = 'hub.app.token';

/// One app registered on a hub.
class HubApp {
  const HubApp({
    required this.id,
    required this.hubId,
    required this.control,
    required this.name,
  });

  factory HubApp.fromJson(Map<String, dynamic> json) => HubApp(
    id: json['id'] as String,
    hubId: json['hubId'] as String,
    control: json['control'] as String,
    name: json['name'] as String,
  );

  /// `hub.<token id>`: it follows the token's id.
  final String id;

  /// The hub's market listing it was registered on.
  final String hubId;

  /// The hub's control address the token is presented at.
  final String control;

  /// What the person calls it.
  final String name;

  HubApp renamed(String value) =>
      HubApp(id: id, hubId: hubId, control: control, name: value);

  Map<String, dynamic> toJson() => {
    'id': id,
    'hubId': hubId,
    'control': control,
    'name': name,
  };
}

/// Why the hub would not let a token in, in the words the person reads.
enum HubEntryReason { tokenShape, tokenBad, offline, gone, forbidden, other }

/// A refusal at the hub's door as it came: the HTTP status, the error code and
/// the gateway code (`-33003` not connected, `-33001` closed).
class HubEntryRefused implements Exception {
  const HubEntryRefused(this.status, this.code, [this.gatewayCode]);

  final int status;
  final String? code;
  final int? gatewayCode;

  /// The server is not on the hub right now.
  bool get offline => code == 'provider_offline' || gatewayCode == -33003;

  HubEntryReason get reason {
    if (offline) return HubEntryReason.offline;
    if (gatewayCode == -33001) return HubEntryReason.gone;
    return switch (code) {
      'invalid_token' => HubEntryReason.tokenBad,
      'not_found' => HubEntryReason.gone,
      'forbidden' || 'token_node_mismatch' => HubEntryReason.forbidden,
      _ => HubEntryReason.other,
    };
  }

  @override
  String toString() => 'HubEntryRefused($status, $code, $gatewayCode)';
}

/// What went wrong with a token, as a reason the screen words.
HubEntryReason hubEntryReasonOf(Object error) {
  if (error is HubEntryRefused) return error.reason;
  if (error is FormatException) return HubEntryReason.tokenShape;
  return HubEntryReason.other;
}

/// The id a hub token carries (`hst_<id>.<secret>`), or null if [token] is not
/// shaped like one. The id names the connection; the secret stays out.
String? hubTokenId(String token) {
  const head = 'hst_';
  if (!token.startsWith(head)) return null;
  final dot = token.indexOf('.');
  if (dot <= head.length || dot == token.length - 1) return null;
  return token.substring(head.length, dot);
}

/// The hub's own door: lets a token in.
abstract class HubEntryPort {
  /// The relay coordinates of one session at [control]. A refusal is thrown as
  /// [HubEntryRefused].
  Future<HubGrant> enter(String control, String token);
}

/// [HubEntryPort] over the hub's HTTP control address. No market login rides
/// with it: the token is the whole credential.
class HttpHubEntryPort implements HubEntryPort {
  HttpHubEntryPort({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<HubGrant> enter(String control, String token) async {
    final root =
        control.endsWith('/')
            ? control.substring(0, control.length - 1)
            : control;
    final r = await _client.post(
      Uri.parse('$root/hub/sessions'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'token': token,
        'policy': {'mode': 'unlimited'},
      }),
    );
    Map<String, dynamic> body;
    try {
      final v = jsonDecode(r.body);
      body = v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};
    } on FormatException {
      body = const <String, dynamic>{};
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      final error = body['error'];
      final map = error is Map ? error : body;
      final gateway = map['gatewayCode'] ?? body['gatewayCode'];
      final code = map['code'];
      throw HubEntryRefused(
        r.statusCode,
        code is String ? code : null,
        gateway is num ? gateway.toInt() : null,
      );
    }
    return HubGrant.fromJson(body);
  }
}

/// Where the app list and its tokens are kept.
abstract class HubAppStore {
  Future<List<HubApp>> apps();
  Future<void> save(HubApp app, String token);
  Future<String?> token(String id);
  Future<void> forget(String id);
}

/// Keeps the list and the tokens in the OS keychain, per market account.
class SecureHubAppStore implements HubAppStore {
  SecureHubAppStore(this._storage, this._accountId);

  final SecureStorage _storage;
  final String _accountId;

  String _tokenKey(String id) => '$_accountId:$id';

  @override
  Future<List<HubApp>> apps() async {
    final raw = await _storage.read(_accountId, namespace: kHubAppsNamespace);
    if (raw == null || raw.isEmpty) return const <HubApp>[];
    return [
      for (final row in jsonDecode(raw) as List)
        HubApp.fromJson((row as Map).cast<String, dynamic>()),
    ];
  }

  Future<void> _write(List<HubApp> apps) => _storage.write(
    _accountId,
    jsonEncode([for (final a in apps) a.toJson()]),
    namespace: kHubAppsNamespace,
  );

  @override
  Future<void> save(HubApp app, String token) async {
    final all = [
      for (final a in await apps())
        if (a.id != app.id) a,
      app,
    ];
    await _storage.write(
      _tokenKey(app.id),
      token,
      namespace: kHubAppTokenNamespace,
    );
    await _write(all);
  }

  @override
  Future<String?> token(String id) async {
    final v = await _storage.read(
      _tokenKey(id),
      namespace: kHubAppTokenNamespace,
    );
    return v == null || v.isEmpty ? null : v;
  }

  @override
  Future<void> forget(String id) async {
    await _storage.delete(_tokenKey(id), namespace: kHubAppTokenNamespace);
    await _write([
      for (final a in await apps())
        if (a.id != id) a,
    ]);
  }
}

/// The outcome of registering an app.
class HubAppAdded {
  const HubAppAdded(this.app, this.grant);

  final HubApp app;

  /// The session the hub opened, or null when the server was not on the hub
  /// (the token is kept; the app opens once the server is connected).
  final HubGrant? grant;

  bool get reached => grant != null;
}

/// The apps of the hubs a person installed: add, change a token, remove.
class HubApps {
  HubApps({required HubAppStore store, required HubEntryPort entry})
    : _store = store,
      _entry = entry;

  final HubAppStore _store;
  final HubEntryPort _entry;

  Future<List<HubApp>> list(String hubId) async => [
    for (final a in await _store.apps())
      if (a.hubId == hubId) a,
  ];

  Future<List<HubApp>> all() => _store.apps();

  Future<String?> tokenOf(String appId) => _store.token(appId);

  /// A fresh session for a saved app.
  Future<HubGrant> open(HubApp app) async {
    final token = await _store.token(app.id);
    if (token == null) {
      throw const HubEntryRefused(401, 'invalid_token');
    }
    return _entry.enter(app.control, token);
  }

  /// Registers an app named [name] with [token] on a hub. A wrong token is
  /// refused and nothing is kept; a good token whose server is not on the hub
  /// is kept ([HubAppAdded.reached] is false).
  Future<HubAppAdded> add({
    required String hubId,
    required String control,
    required String fallbackName,
    required String name,
    required String token,
  }) async {
    final value = token.trim();
    final tokenId = hubTokenId(value);
    if (tokenId == null) throw const FormatException('hub token');
    final label = name.trim().isEmpty ? fallbackName : name.trim();
    HubGrant? grant;
    try {
      grant = await _entry.enter(control, value);
    } on HubEntryRefused catch (e) {
      if (!e.offline) rethrow;
    }
    final app = HubApp(
      id: 'hub.$tokenId',
      hubId: hubId,
      control: control,
      name: label,
    );
    await _store.save(app, value);
    return HubAppAdded(app, grant);
  }

  /// Gives [app] another token. A token with another id is another app, so the
  /// old entry goes once the new one is in; a refused token changes nothing.
  Future<HubAppAdded> changeToken(HubApp app, String token) async {
    final added = await add(
      hubId: app.hubId,
      control: app.control,
      fallbackName: app.name,
      name: app.name,
      token: token,
    );
    if (added.app.id != app.id) await _store.forget(app.id);
    return added;
  }

  Future<void> rename(HubApp app, String name) async {
    final token = await _store.token(app.id);
    if (token != null) await _store.save(app.renamed(name), token);
  }

  /// Takes [app] off its hub: its entry and its token.
  Future<void> remove(HubApp app) => _store.forget(app.id);
}
