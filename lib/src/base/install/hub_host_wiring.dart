/// One call mounts the hub on a host: the consume side (several hubs by
/// market identity) and the expose side (this machine as a node), plus the
/// `hub.*` tools. Studio Pro and the workbench call it with their own market
/// sign-in; nothing here knows how the user logs in.
library;

import 'dart:convert';

import 'package:appplayer_secure/appplayer_secure.dart' show SecureStorage;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:http/http.dart' as http;

import 'hub_apps.dart';
import 'hub_capability.dart';
import 'hub_connections.dart';
import 'hub_node_host.dart';
import 'hub_space.dart';
import 'market_app_check.dart';

/// Keychain namespace for the node registration (it carries the relay secret).
const String kHubNodeNamespace = 'hub.node';

/// Tools a remote caller must not reach: the hub's own node controls.
const Set<String> kHubRemoteExcluded = <String>{
  'hub.node_start',
  'hub.node_stop',
  'hub.node_remove',
};

/// Keeps the node registration in the OS keychain, one per market account.
class SecureHubNodeStore implements HubNodeStore {
  SecureHubNodeStore(this._storage, this._accountId);

  final SecureStorage _storage;
  final String _accountId;

  @override
  Future<HubNodeRegistration?> load() async {
    final raw = await _storage.read(_accountId, namespace: kHubNodeNamespace);
    if (raw == null || raw.isEmpty) return null;
    return HubNodeRegistration.fromJson(
      (jsonDecode(raw) as Map).cast<String, dynamic>(),
    );
  }

  @override
  Future<void> save(HubNodeRegistration registration) => _storage.write(
    _accountId,
    jsonEncode(registration.toJson()),
    namespace: kHubNodeNamespace,
  );

  @override
  Future<void> clear() =>
      _storage.delete(_accountId, namespace: kHubNodeNamespace);
}

/// What [HubHost.join] did.
class HubJoinOutcome {
  const HubJoinOutcome({this.nodeStarted = false, this.error});

  final bool nodeStarted;

  /// The failure, if the node could not go online (for example the account
  /// has not done the one-time developer registration).
  final String? error;
}

/// What [mountHub] hands back; the host disposes it on sign-out.
class HubHost {
  HubHost._(this.connections, this.node, this.capability, this.space);

  final HubConnections connections;
  final HubNodeHost node;
  final HubCapability capability;

  /// The hubs of this host: Arche plus the installed market hubs.
  final HubSpace space;

  /// The default flow on sign-in: put this machine online as a hub node and
  /// keep it connected. Never throws; a failure stays readable in the node's
  /// state and through `hub.status`.
  Future<HubJoinOutcome> join() async {
    try {
      await space.restore();
    } catch (e) {
      return HubJoinOutcome(error: '$e');
    }
    final online = node.state == HubNodeState.online;
    return HubJoinOutcome(
      nodeStarted: online,
      error: node.error ?? space.lastError,
    );
  }

  Future<void> dispose() async {
    await capability.dispose();
    space.dispose();
    await node.dispose();
    await connections.dispose();
  }
}

/// Mount the hub on [boot] for the signed-in market account.
///
/// - [baseUrl]: the market origin (`/market/**` and `/hub/**` live there).
/// - [token]: the signed-in user's market token provider.
/// - [appCheckToken]: this app's native App Check token (null on desktop); the
///   market's `/market/**` rejects calls without one, so a missing token is
///   minted by the market.
/// - [accountId]: the market uid; keys the stored node registration.
HubHost mountHub({
  required mk.KernelServerHost boot,
  required String baseUrl,
  required Future<String?> Function() token,
  required String accountId,
  required SecureStorage storage,
  HubNodePolicy policy = const HubNodePolicy(),
  HubClientSetup? clientSetup,
  Duration? hubCallTimeout,
  Duration? hubKeepAlive,
  Future<String?> Function()? appCheckToken,
  http.Client? client,
  HubChannelOpener openHub = openRelayChannel,
  HubNodeChannelOpener openNode = openRelayNodeChannel,
}) {
  final registry = mk.HostToolRegistry(
    endpoint: boot,
    attachToDispatcher: (_, _) {},
    detachFromDispatcher: (_) {},
  );
  // The market's doors want App Check; desktop has no native provider, so the
  // market mints one for this app.
  final check = marketAppCheck(
    baseUrl: baseUrl,
    native: appCheckToken,
    client: client,
  );
  // Servers are opened with hub tokens: the hub lets a token holder in without
  // a market login, and the relay carries the session. Arche is one of them.
  final connections = HubConnections(
    market: const HubTokenOnlyMarket(),
    open: openHub,
    // An app's server may start its node on the first call, so the first
    // request gets room.
    handshakeTimeout: const Duration(seconds: 45),
    clientSetup: clientSetup,
    callTimeout: hubCallTimeout,
    keepAlive: hubKeepAlive,
  );
  final apps = HubApps(
    store: SecureHubAppStore(storage, accountId),
    entry: HttpHubEntryPort(client: client),
  );
  final node = HubNodeHost(
    port: HttpHubNodePort(
      baseUrl: baseUrl,
      token: token,
      appCheckToken: check,
      client: client,
    ),
    store: SecureHubNodeStore(storage, accountId),
    tools: KernelHostToolSurface(boot, exclude: kHubRemoteExcluded),
    policy: policy,
    ownerSubject: accountId,
    open: openNode,
  );
  final surface = KernelHostToolSurface(boot, exclude: kHubRemoteExcluded);
  final space = HubSpace(
    items: HttpHubItemsPort(
      baseUrl: baseUrl,
      token: token,
      appCheckToken: check,
      client: client,
    ),
    arche: node,
    // One node per installed hub, registered at that hub's own control address.
    nodeFor:
        (item) => HubNodeHost(
          port: HttpHubNodePort(
            baseUrl: baseUrl,
            hubBaseUrl: item.control,
            token: token,
            appCheckToken: check,
            client: client,
          ),
          store: SecureHubNodeStore(storage, '$accountId:${item.listingId}'),
          tools: surface,
          policy: policy,
          ownerSubject: accountId,
          open: openNode,
        ),
    attachStore: SecureHubAttachStore(storage, accountId),
    apps: apps,
    appTools: connections,
  );
  final capability = HubCapability(
    registry: registry,
    connections: connections,
    node: node,
    space: space,
  );
  return HubHost._(connections, node, capability, space);
}
