/// Where a host gathers its hubs (platform spec 15 §10.3): hubs found and
/// installed as market items, and this machine put online as a node on each of
/// them. The market gives no screen; a host draws one screen over this model.
library;

import 'dart:async';
import 'dart:convert';

import 'package:appplayer_secure/appplayer_secure.dart' show SecureStorage;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'hub_apps.dart';
import 'hub_connections.dart'
    show HubConnectionError, HubConnections, HubGrant, HubLinkState;
import 'hub_node_host.dart';
import 'market_app_check.dart' show marketIdentityHeaders;

/// Id of the Arche entry in the hub space.
const String kArcheHubId = 'arche';

/// Market listing of the Arche hub item. Arche is installed from the market
/// like any hub; its app is opened with a hub token Arche issued.
const String kArcheListingId = '6111f706-5afa-4dc9-8c9d-e73d8cc6a449';

/// Keychain namespace of the attached set (hub ids, one list per account).
const String kHubAttachNamespace = 'hub.attached';

/// One hub as a market item (`type=hub`).
class HubItem {
  const HubItem({
    required this.listingId,
    required this.title,
    this.icon,
    this.description,
    required this.control,
    required this.relay,
  });

  factory HubItem.fromJson(Map<String, dynamic> json) {
    final hub = json['hub'];
    if (hub is! Map || hub['control'] is! String) {
      throw const FormatException('hub item lacks hub.control');
    }
    return HubItem(
      listingId: (json['listingId'] ?? json['id']) as String,
      title: (json['title'] ?? json['name'] ?? json['listingId']) as String,
      icon: json['icon'] as String?,
      description: json['description'] as String?,
      control: hub['control'] as String,
      relay: (hub['relay'] as String?) ?? '',
    );
  }

  final String listingId;
  final String title;
  final String? icon;
  final String? description;

  /// `https` control address (`/hub/nodes` lives here).
  final String control;

  /// `wss` relay address.
  final String relay;
}

/// The market doors a hub space uses, in the order spec 15 §10.3 fixes.
abstract class HubItemsPort {
  /// `GET /market/catalog?type=hub`
  Future<List<HubItem>> catalog();

  /// `GET /market/me/items?type=hub`
  Future<List<HubItem>> installed();

  /// `POST /market/purchase {listingId}` — free items are installed on the spot.
  Future<void> install(String listingId);

  /// `POST /market/me/items/:id/visibility {hidden:true}`
  Future<void> hide(String listingId);
}

/// [HubItemsPort] over the market's HTTP API with the signed-in user's token.
class HttpHubItemsPort implements HubItemsPort {
  HttpHubItemsPort({
    required this.baseUrl,
    required this.token,
    this.appCheckToken,
    this.workspace,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final Future<String?> Function() token;
  final Future<String?> Function()? appCheckToken;

  /// The market workspace the account stands in (`X-AppPlayer-Workspace`).
  /// When null it is asked of the market once (`GET /market/me/workspaces`):
  /// an account that belongs to no workspace sends no header (personal
  /// place); a member sends its first workspace.
  final Future<String?> Function()? workspace;

  bool _asked = false;
  String? _asking;

  Future<String?> _workspaceId(Map<String, String> base) async {
    final given = workspace;
    if (given != null) return given();
    if (_asked) return _asking;
    final r = await _client.get(
      Uri.parse('$baseUrl/market/me/workspaces'),
      headers: base,
    );
    final json = _decode(r);
    final list =
        json is List
            ? json
            : (json is Map ? (json['workspaces'] ?? json['items']) : null);
    String? first;
    for (final w in (list as List? ?? const <Object?>[])) {
      if (w is Map) {
        final id = w['id'] ?? w['wid'];
        if (id is String && id.isNotEmpty) {
          first = id;
          break;
        }
      }
    }
    _asked = true;
    return _asking = first;
  }

  final http.Client _client;

  Future<Map<String, String>> _headers({bool withWorkspace = true}) async {
    final t = await token();
    if (t == null || t.isEmpty) {
      throw const HubConnectionError(
        'hub.not_signed_in',
        'sign in to the market to use hubs',
      );
    }
    final check = await appCheckToken?.call();
    final base = <String, String>{
      'authorization': 'Bearer $t',
      'content-type': 'application/json',
      ...marketIdentityHeaders(),
      if (check != null && check.isNotEmpty) 'X-Firebase-AppCheck': check,
    };
    if (withWorkspace) {
      final wid = await _workspaceId(base);
      if (wid != null && wid.isNotEmpty) base['X-AppPlayer-Workspace'] = wid;
    }
    return base;
  }

  Object? _decode(http.Response r) {
    final json = r.body.isEmpty ? null : jsonDecode(r.body);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      final err = json is Map ? json['error'] : null;
      final message =
          err is Map
              ? err['message']
              : (err is String ? err : (json is Map ? json['message'] : null));
      throw HubConnectionError(
        'hub.market_${r.statusCode}',
        '${message ?? 'market error'}',
      );
    }
    return json;
  }

  List<HubItem> _items(Object? json) {
    final list =
        json is List
            ? json
            : (json is Map ? (json['items'] ?? json['listings']) : null);
    return <HubItem>[
      for (final e in (list as List? ?? const <Object?>[]))
        if (e is Map && e['hub'] is Map)
          HubItem.fromJson(e.cast<String, dynamic>()),
    ];
  }

  @override
  Future<List<HubItem>> catalog() async => _items(
    _decode(
      await _client.get(
        Uri.parse(
          '$baseUrl/market/catalog',
        ).replace(queryParameters: const <String, String>{'type': 'hub'}),
        headers: await _headers(),
      ),
    ),
  );

  @override
  Future<List<HubItem>> installed() async => _items(
    _decode(
      await _client.get(
        Uri.parse(
          '$baseUrl/market/me/items',
        ).replace(queryParameters: const <String, String>{'type': 'hub'}),
        headers: await _headers(),
      ),
    ),
  );

  @override
  Future<void> install(String listingId) async {
    _decode(
      await _client.post(
        Uri.parse('$baseUrl/market/purchase'),
        headers: await _headers(),
        body: jsonEncode(<String, dynamic>{'listingId': listingId}),
      ),
    );
  }

  @override
  Future<void> hide(String listingId) async {
    _decode(
      await _client.post(
        Uri.parse('$baseUrl/market/me/items/$listingId/visibility'),
        headers: await _headers(),
        body: jsonEncode(<String, dynamic>{'hidden': true}),
      ),
    );
  }
}

/// Remembers which hubs this account keeps this host attached to.
abstract class HubAttachStore {
  /// `null` = never chosen (the built-in default applies).
  Future<Set<String>?> load();
  Future<void> save(Set<String> ids);
}

class SecureHubAttachStore implements HubAttachStore {
  SecureHubAttachStore(this._storage, this._accountId);

  final SecureStorage _storage;
  final String _accountId;

  @override
  Future<Set<String>?> load() async {
    final raw = await _storage.read(_accountId, namespace: kHubAttachNamespace);
    if (raw == null || raw.isEmpty) return null;
    return (jsonDecode(raw) as List).cast<String>().toSet();
  }

  @override
  Future<void> save(Set<String> ids) => _storage.write(
    _accountId,
    jsonEncode(ids.toList()..sort()),
    namespace: kHubAttachNamespace,
  );
}

/// One app of a hub as the screen reads it.
class HubAppView {
  const HubAppView({
    required this.app,
    required this.state,
    this.reason,
    this.error,
    this.toolNames = const <String>[],
  });

  final HubApp app;

  /// The connection state; null when the app is not open (its server is not on
  /// the hub, or it was refused).
  final HubLinkState? state;

  /// Why the hub would not open it, when it refused.
  final HubEntryReason? reason;
  final String? error;
  final List<String> toolNames;

  bool get connected => state == HubLinkState.connected;
}

/// One line of the hub screen.
class HubEntry {
  const HubEntry({
    required this.id,
    required this.title,
    this.icon,
    this.description,
    required this.isArche,
    required this.state,
    this.error,
    this.nodeId,
    this.control,
    this.relay,
    this.apps = const <HubAppView>[],
  });

  final String id;
  final String title;
  final String? icon;
  final String? description;

  /// The Arche entry (installed from the market, connected through its lane).
  final bool isArche;
  final HubNodeState state;
  final String? error;
  final String? nodeId;

  /// The hub's control and relay addresses.
  final String? control;
  final String? relay;

  /// Apps registered on this hub, each opened with its own hub token.
  final List<HubAppView> apps;

  bool get attached =>
      state == HubNodeState.online ||
      state == HubNodeState.registering ||
      state == HubNodeState.connecting ||
      state == HubNodeState.reconnecting;
}

/// Builds the node host that puts this machine on [item].
typedef HubNodeFactory = HubNodeHost Function(HubItem item);

class HubSpace extends ChangeNotifier {
  HubSpace({
    required HubItemsPort items,
    required HubNodeHost arche,
    required HubNodeFactory nodeFor,
    required HubAttachStore attachStore,
    HubApps? apps,
    HubConnections? appTools,
  }) : _items = items,
       _arche = arche,
       _nodeFor = nodeFor,
       _store = attachStore,
       _appList = apps,
       _appTools = appTools {
    _watch(kArcheHubId, arche);
    _appsSub = appTools?.changes.listen((_) => _changed());
  }

  final HubApps? _appList;
  final HubConnections? _appTools;
  StreamSubscription<void>? _appsSub;
  List<HubApp> _apps = const <HubApp>[];
  final Map<String, HubEntryReason> _appReasons = <String, HubEntryReason>{};

  final HubItemsPort _items;
  final HubNodeHost _arche;
  final HubNodeFactory _nodeFor;
  final HubAttachStore _store;

  final Map<String, HubItem> _installed = <String, HubItem>{};
  final Map<String, HubNodeHost> _hosts = <String, HubNodeHost>{};
  final Map<String, StreamSubscription<HubNodeState>> _subs =
      <String, StreamSubscription<HubNodeState>>{};
  Set<String> _attached = <String>{kArcheHubId};
  bool _disposed = false;

  /// Whether the Arche hub item is installed on this account.
  bool get archeInstalled => _installed.containsKey(kArcheListingId);

  /// Arche first (when installed), then the other installed hubs.
  List<HubEntry> get entries => <HubEntry>[
    if (archeInstalled) _archeEntry(),
    for (final item in _installed.values)
      if (item.listingId != kArcheListingId)
        _entry(
          item.listingId,
          item.title,
          item.icon,
          item.description,
          _hosts[item.listingId],
          isArche: false,
        ),
  ];

  HubEntry _archeEntry() {
    return HubEntry(
      id: kArcheHubId,
      title: _installed[kArcheListingId]?.title ?? 'Arche',
      icon: _installed[kArcheListingId]?.icon,
      description: _installed[kArcheListingId]?.description,
      isArche: true,
      state: _arche.state,
      error: _arche.error,
      nodeId: _arche.nodeId,
      control: _installed[kArcheListingId]?.control,
      relay: _installed[kArcheListingId]?.relay,
      apps: _viewsOf(kArcheListingId),
    );
  }

  HubEntry _entry(
    String id,
    String title,
    String? icon,
    String? description,
    HubNodeHost? host, {
    required bool isArche,
  }) => HubEntry(
    id: id,
    title: title,
    icon: icon,
    description: description,
    isArche: isArche,
    state: host?.state ?? HubNodeState.stopped,
    error: host?.error,
    nodeId: host?.nodeId,
    control: _installed[id]?.control,
    relay: _installed[id]?.relay,
    apps: _viewsOf(id),
  );

  List<HubAppView> _viewsOf(String hubId) => [
    for (final app in _apps)
      if (app.hubId == hubId) _view(app),
  ];

  HubAppView _view(HubApp app) {
    final link = _appTools?.linkOf(app.id);
    return HubAppView(
      app: app,
      state: link?.state,
      reason: _appReasons[app.id],
      error: link?.error,
      toolNames: link?.toolNames ?? const <String>[],
    );
  }

  void _watch(String id, HubNodeHost host) {
    _subs[id] = host.states.listen((_) => _changed());
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Hubs of the catalog that are not installed yet.
  Future<List<HubItem>> find() async {
    final all = await _items.catalog();
    return <HubItem>[
      for (final h in all)
        if (!_installed.containsKey(h.listingId)) h,
    ];
  }

  /// Re-read the installed list and bring the attached ones online. Arche,
  /// once installed, is attached unless the account turned it off.
  Future<void> restore() async {
    _attached = await _store.load() ?? <String>{kArcheHubId};
    String? failure;
    try {
      await _sync(await _items.installed());
    } catch (e) {
      failure = e is HubConnectionError ? '${e.message} (${e.code})' : '$e';
    }
    final starts = <Future<void>>[
      for (final id in _attached)
        if (id == kArcheHubId ? archeInstalled : _installed.containsKey(id))
          _start(id).catchError((Object _) {}),
    ];
    final list = _appList;
    if (list != null) {
      try {
        _apps = await list.all();
      } catch (_) {
        _apps = const <HubApp>[];
      }
      starts.addAll([
        for (final app in _apps)
          if (_installed.containsKey(app.hubId))
            _connectApp(app).catchError((Object _) {}),
      ]);
    }
    await Future.wait(starts);
    _changed();
    if (failure != null) lastError = failure;
  }

  /// Why the last list read failed, if it did.
  String? lastError;

  Future<void> _sync(List<HubItem> now) async {
    final ids = {for (final h in now) h.listingId};
    for (final gone
        in _installed.keys.where((k) => !ids.contains(k)).toList()) {
      for (final app in _apps.where((a) => a.hubId == gone)) {
        await _appTools?.disconnect(app.id);
      }
      if (gone == kArcheListingId) await _closeArche();
      await _drop(gone);
    }
    for (final item in now) {
      _installed[item.listingId] = item;
    }
    lastError = null;
  }

  Future<void> _drop(String id) async {
    _installed.remove(id);
    await _subs.remove(id)?.cancel();
    final host = _hosts.remove(id);
    if (host != null) await host.dispose();
  }

  /// Open one saved app through its hub. A refusal is kept as its reason and
  /// the app stays registered, so it opens when the server is on the hub.
  Future<void> _connectApp(HubApp app, [HubGrant? first]) async {
    final list = _appList;
    final tools = _appTools;
    if (list == null || tools == null) return;
    HubGrant grant;
    try {
      grant = first ?? await list.open(app);
    } on HubEntryRefused catch (e) {
      _appReasons[app.id] = e.reason;
      _changed();
      return;
    }
    _appReasons.remove(app.id);
    await tools.connectGranted(
      id: app.id,
      title: app.name,
      grant: () async => _wire(app, await list.open(app)),
      first: _wire(app, grant),
    );
    _changed();
  }

  /// Arche's relay carries plain MCP JSON-RPC; every other hub speaks the hub
  /// wire.
  HubGrant _wire(HubApp app, HubGrant grant) =>
      app.hubId == kArcheListingId
          ? HubGrant(
            sessionId: grant.sessionId,
            relayUrl: grant.relayUrl,
            relayToken: grant.relayToken,
            audience: grant.audience,
            plainMcp: true,
          )
          : grant;

  HubApps get _appsOrThrow =>
      _appList ??
      (throw const HubConnectionError(
        'hub.apps_unavailable',
        'this host has no hub token apps',
      ));

  /// The market listing an entry id stands for (the Arche entry keeps its
  /// own id).
  static String _listingOf(String id) =>
      id == kArcheHubId ? kArcheListingId : id;

  HubItem _hubOf(String listingId) {
    final item = _installed[listingId];
    if (item == null) {
      throw HubConnectionError(
        'hub.not_installed',
        'hub $listingId is not installed',
      );
    }
    return item;
  }

  /// The nodes of this account on a hub, with the hub's own state for each.
  Future<List<HubNodeInfo>> nodesOf(String id) => _hostOf(id).nodes();

  /// Takes one of the account's nodes off a hub.
  Future<void> releaseNode(String id, String nodeId) async {
    final host = _hostOf(id);
    await host.releaseNode(nodeId);
    if (host.nodeId == nodeId) await host.stop();
    _changed();
  }

  /// How often the hub checks this machine's node on [id] (0 = never).
  Future<void> setHeartbeat(String id, int seconds) async {
    await _hostOf(id).setHeartbeat(seconds);
    _changed();
  }

  /// The apps registered on [hubId].
  List<HubAppView> appsOf(String hubId) => _viewsOf(_listingOf(hubId));

  /// Registers an app with its hub token and opens it. A wrong token is
  /// refused and nothing is kept; a good token whose server is not on the hub
  /// is kept and the result says it was not reached.
  Future<HubAppAdded> addApp(String hub, String name, String token) async {
    final hubId = _listingOf(hub);
    // Right after boot the installed list may not have been read yet.
    if (!_installed.containsKey(hubId)) {
      try {
        await _sync(await _items.installed());
      } catch (_) {
        // Falls through to the not-installed answer below.
      }
    }
    final item = _hubOf(hubId);
    final added = await _appsOrThrow.add(
      hubId: hubId,
      control: item.control,
      fallbackName: item.title,
      name: name,
      token: token,
    );
    _apps = await _appsOrThrow.all();
    _appReasons.remove(added.app.id);
    if (added.reached) {
      await _connectApp(added.app, added.grant);
    } else {
      _appReasons[added.app.id] = HubEntryReason.offline;
    }
    _changed();
    return added;
  }

  /// Gives an app another token; the old token stays if the new one is
  /// refused.
  Future<HubAppAdded> changeAppToken(String appId, String token) async {
    final old = _appOf(appId);
    final added = await _appsOrThrow.changeToken(old, token);
    if (added.app.id != old.id) await _appTools?.disconnect(old.id);
    _apps = await _appsOrThrow.all();
    _appReasons.remove(old.id);
    if (added.reached) {
      await _connectApp(added.app, added.grant);
    } else {
      _appReasons[added.app.id] = HubEntryReason.offline;
    }
    _changed();
    return added;
  }

  /// Takes an app off its hub: closed, its token and entry forgotten.
  Future<void> removeApp(String appId) async {
    final app = _appOf(appId);
    await _appTools?.disconnect(app.id);
    await _appsOrThrow.remove(app);
    _appReasons.remove(app.id);
    _apps = await _appsOrThrow.all();
    _changed();
  }

  /// Opens a saved app again (for example once its server is back).
  Future<void> openApp(String appId) => _connectApp(_appOf(appId));

  HubApp _appOf(String appId) {
    for (final a in _apps) {
      if (a.id == appId) return a;
    }
    throw HubConnectionError('hub.app_unknown', 'no app $appId');
  }

  /// Put Arche offline (it left the account).
  Future<void> _closeArche() => _arche.stop();

  HubNodeHost _hostOf(String id) {
    if (id == kArcheHubId) {
      if (!archeInstalled) {
        throw const HubConnectionError(
          'hub.not_installed',
          'install the Arche hub from the market first',
        );
      }
      return _arche;
    }
    final item = _installed[id];
    if (item == null) {
      throw HubConnectionError('hub.not_installed', 'hub $id is not installed');
    }
    return _hosts.putIfAbsent(id, () {
      final host = _nodeFor(item);
      _watch(id, host);
      return host;
    });
  }

  Future<void> _start(String id) => _hostOf(id).start();

  /// Put this machine online on [id] and remember it.
  Future<void> attach(String id) async {
    _attached = <String>{..._attached, id};
    await _store.save(_attached);
    try {
      await _start(id);
    } finally {
      _changed();
    }
  }

  /// Take this machine off [id] and remember it.
  Future<void> detach(String id) async {
    _attached = <String>{..._attached}..remove(id);
    await _store.save(_attached);
    await _hostOf(id).stop();
    _changed();
  }

  /// Install a found hub; it joins the list detached. Arche's node comes up
  /// on its remembered (default: attached) choice.
  Future<void> install(String listingId) async {
    await _items.install(listingId);
    await _sync(await _items.installed());
    if (listingId == kArcheListingId && archeInstalled) {
      _attached = await _store.load() ?? <String>{kArcheHubId};
      if (_attached.contains(kArcheHubId)) {
        await _start(kArcheHubId).catchError((Object _) {});
      }
    }
    _changed();
  }

  /// Remove a hub from the list: offline, forgotten, hidden in the market.
  Future<void> hide(String id) async {
    if (id == kArcheHubId || id == kArcheListingId) {
      for (final app
          in _apps.where((a) => a.hubId == kArcheListingId).toList()) {
        await removeApp(app.id);
      }
      await _closeArche();
      await _items.hide(kArcheListingId);
      await _drop(kArcheListingId);
      _changed();
      return;
    }
    for (final app in _apps.where((a) => a.hubId == id).toList()) {
      await removeApp(app.id);
    }
    final host = _hosts[id];
    if (host != null) await host.unregister();
    _attached = <String>{..._attached}..remove(id);
    await _store.save(_attached);
    await _items.hide(id);
    await _drop(id);
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_appsSub?.cancel());
    for (final s in _subs.values) {
      unawaited(s.cancel());
    }
    _subs.clear();
    for (final h in _hosts.values) {
      unawaited(h.dispose());
    }
    _hosts.clear();
    super.dispose();
  }
}
