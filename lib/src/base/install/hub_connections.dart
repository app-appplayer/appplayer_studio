/// Hub connections — the consumer side of the market hub for a host.
///
/// The host logs in to the market, asks it which hubs the account may join
/// (optionally narrowed to one service such as `arche`), picks one, several
/// or all, and each pick becomes an independent relay session whose tools are
/// surfaced as ordinary MCP tools. No address is ever typed: the market
/// hands out a short-lived grant per hub (spec market/11 §4-1, §4-2).
///
/// Host wiring only. The relay frames, the consumer and the MCP surfacing live
/// in the vendored `gateway_node` recipe; the market doors are injected through
/// [HubMarketPort] so a host with its own market client reuses it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:mcp_client/mcp_client.dart';

import 'gateway_node/gateway_node.dart';
import 'plain_mcp_transport.dart';

/// A hub the account may join (`GET /market/me/hubs`). Carries no address.
class HubChoice {
  const HubChoice({
    required this.listingId,
    required this.title,
    required this.via,
    required this.mine,
    this.icon,
  });

  factory HubChoice.fromJson(Map<String, dynamic> json) => HubChoice(
    listingId: json['listingId'] as String,
    title: json['title'] as String,
    via: (json['via'] as String?) ?? '',
    mine: json['mine'] == true,
    icon: json['icon'] as String?,
  );

  final String listingId;
  final String title;
  final String via;
  final bool mine;
  final String? icon;
}

/// The relay coordinates the market issues for one session.
class HubGrant {
  const HubGrant({
    required this.sessionId,
    required this.relayUrl,
    required this.relayToken,
    this.audience,
    this.plainMcp = false,
  });

  factory HubGrant.fromJson(Map<String, dynamic> json) {
    final sessionId = json['sessionId'];
    final relayUrl = json['relayUrl'];
    final relayToken = json['relayToken'];
    if (sessionId is! String || relayUrl is! String || relayToken is! String) {
      throw const FormatException(
        'hub grant lacks sessionId / relayUrl / relayToken',
      );
    }
    return HubGrant(
      sessionId: sessionId,
      relayUrl: relayUrl,
      relayToken: relayToken,
      audience: json['audience'] as String?,
    );
  }

  /// The peer speaks plain MCP JSON-RPC on the socket (the Arche lane); the
  /// default is the hub wire of market hubs.
  final bool plainMcp;

  final String sessionId;
  final String relayUrl;
  final String relayToken;
  final String? audience;
}

/// One line of `POST /market/me/hubs/connect`: a grant or the reason it was
/// refused. A refused hub never fails its siblings.
class HubConnectOutcome {
  const HubConnectOutcome({
    required this.listingId,
    this.grant,
    this.errorCode,
    this.errorMessage,
  });

  factory HubConnectOutcome.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    if (error is Map) {
      return HubConnectOutcome(
        listingId: json['listingId'] as String,
        errorCode: error['code'] as String?,
        errorMessage: error['message'] as String?,
      );
    }
    return HubConnectOutcome(
      listingId: json['listingId'] as String,
      grant: HubGrant.fromJson((json['grant'] as Map).cast<String, dynamic>()),
    );
  }

  final String listingId;
  final HubGrant? grant;
  final String? errorCode;
  final String? errorMessage;
}

/// The market's two hub doors.
abstract class HubMarketPort {
  Future<List<HubChoice>> hubs({String? publisher});

  /// Open the given hubs, or every hub the account may join when [all].
  Future<List<HubConnectOutcome>> connect({
    List<String>? listingIds,
    bool all = false,
    String? publisher,
  });
}

/// The market no longer hands out hub sessions (`/market/me/hubs` is
/// withdrawn): servers are opened with hub tokens. This port lists nothing and
/// refuses a market connect, so only token apps reach a hub.
class HubTokenOnlyMarket implements HubMarketPort {
  const HubTokenOnlyMarket();

  @override
  Future<List<HubChoice>> hubs({String? publisher}) async =>
      const <HubChoice>[];

  @override
  Future<List<HubConnectOutcome>> connect({
    List<String>? listingIds,
    bool all = false,
    String? publisher,
  }) async => [
    for (final id in listingIds ?? const <String>[])
      HubConnectOutcome(
        listingId: id,
        errorCode: 'hub.token_required',
        errorMessage: 'open this hub with a hub token',
      ),
  ];
}

/// A failure the caller can show and act on — never swallowed.
class HubConnectionError implements Exception {
  const HubConnectionError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'HubConnectionError($code): $message';
}

/// The frame pipe of one relay session.
class HubChannel {
  const HubChannel({
    required this.incoming,
    required this.send,
    required this.close,
    required this.done,
  });

  final Stream<Map<String, dynamic>> incoming;
  final Future<void> Function(Map<String, dynamic> frame) send;
  final Future<void> Function() close;

  /// Completes when the transport ends (expiry, relay restart, network).
  final Future<void> done;
}

/// Opens the relay for a grant. The default speaks to the real relay.
typedef HubChannelOpener = Future<HubChannel> Function(HubGrant grant);

/// The production opener: a `role=client` relay socket carrying raw frames.
Future<HubChannel> openRelayChannel(HubGrant grant) async {
  final socket = await RelaySocket.client(
    relayUrl: grant.relayUrl,
    sessionId: grant.sessionId,
    relayToken: grant.relayToken,
  );
  return HubChannel(
    incoming:
        socket.incoming
            .map((t) {
              try {
                final v = jsonDecode(t);
                return v is Map ? v.cast<String, dynamic>() : null;
              } on FormatException {
                return null;
              }
            })
            .where((m) => m != null)
            .cast<Map<String, dynamic>>(),
    send: (frame) async => socket.send(jsonEncode(frame)),
    close: socket.close,
    done: socket.done,
  );
}

enum HubLinkState { connecting, connected, reconnecting, failed, closed }

/// One live (or failed) hub connection. Sessions are independent per hub.
class HubLink {
  HubLink._(this.listingId, this.title, this.namespace);

  final String listingId;
  final String title;

  /// Prefix that keeps this hub's tool names apart from every other hub's.
  final String namespace;

  HubLinkState state = HubLinkState.connecting;

  /// Why the hub is not usable (`failed`), or the last drop (`reconnecting`).
  String? error;

  /// Remote tool names as the hub serves them (unprefixed).
  List<String> toolNames = const [];

  HubChannel? _channel;
  HubGatewayConsumer? _consumer;
  Client? _client;
  Timer? _renew;
  Timer? _keep;
  int _misses = 0;
  Timer? _quiet;
  Timer? _retry;
  int _retries = 0;
  DateTime _heard = DateTime.now();
  Completer<void> _ready = Completer<void>();

  /// Bumped on every attach so a late signal from a replaced session is ignored.
  int _gen = 0;

  /// How a session is asked for again; null = the market's connect door.
  Future<HubGrant> Function()? _regrant;
}

/// A remote tool as the host sees it.
class HubToolRef {
  const HubToolRef({
    required this.name,
    required this.link,
    required this.remoteName,
    this.description,
    this.inputSchema,
  });

  /// `<namespace>.<remote name>` — unique across hubs.
  final String name;
  final HubLink link;
  final String remoteName;
  final String? description;
  final Map<String, dynamic>? inputSchema;
}

/// What a host lets the hub servers ask of it (the client side of platform
/// spec 06, "external MCP servers"). Without a setup nothing is declared and
/// every server-initiated request is refused, as before.
class HubClientSetup {
  const HubClientSetup({
    required this.capabilities,
    required this.configure,
    this.current,
    this.serverSilence,
    this.onFrame,
  });

  /// Sees each frame the server sends, before the client does. For a host
  /// that must tie a later notification (a cancel) to an earlier request.
  final void Function(Map<String, dynamic> frame)? onFrame;

  /// A connection whose server sends nothing at all for this long is taken
  /// as dropped (the node removed the session without closing the relay) and
  /// is opened again. Null: silence is not watched. Set it only for servers
  /// that send their own `ping`.
  final Duration? serverSilence;

  /// Declared in `initialize`; only what [configure] implements.
  final ClientCapabilities capabilities;

  /// Registers the request handlers for the declared capabilities.
  final void Function(Client client) configure;

  /// When what is declared changes between connections, this gives the
  /// capabilities for the next one; null keeps [capabilities].
  final ClientCapabilities Function()? current;

  ClientCapabilities get declared => current?.call() ?? capabilities;
}

/// Manages the account's hub connections: list, connect (one / several /
/// all), keep them alive across the 30-minute grant, and route tool calls.
class HubConnections {
  HubConnections({
    required HubMarketPort market,
    HubChannelOpener open = openRelayChannel,
    this.renewAfter = const Duration(minutes: 25),
    this.reconnectWait = const Duration(seconds: 20),
    this.handshakeTimeout = const Duration(seconds: 20),
    this.clientName = 'appplayer-hub-client',
    this.clientSetup,
    this.callTimeout,
    this.keepAlive,
    this.rejoinBackoff = _defaultRejoinBackoff,
    Future<void> Function(Client client)? pinger,
  }) : _pinger = pinger ?? _defaultPing,
       _market = market,
       _open = open;

  final HubMarketPort _market;
  final HubChannelOpener _open;

  /// Grants last 30 minutes; renew before they lapse so users see no gap.
  final Duration renewAfter;

  /// How long a call waits for a reconnect before it fails loudly.
  final Duration reconnectWait;

  /// A relay that accepts the socket but never answers must not hang a connect.
  final Duration handshakeTimeout;
  final String clientName;

  /// Null = declare no client capabilities (the default).
  final HubClientSetup? clientSetup;

  /// How long one tool call waits for its answer; null keeps the client's own
  /// default. A server that asks the person something mid-call needs longer
  /// than the default, so a host that answers such requests sets this.
  final Duration? callTimeout;

  /// How often an idle connection is asked whether the hub's server still
  /// answers; two silent rounds in a row open a new session. Null = never ask.
  /// A server that is replaced (redeployed) drops its sessions without the
  /// relay closing this one, so the connection would stay "connected" and
  /// receive nothing.
  final Duration? keepAlive;

  /// How long to wait before the next try when a dropped connection cannot be
  /// reopened; [attempt] counts from 0 and resets once a session is up again.
  final Duration Function(int attempt) rejoinBackoff;

  static Duration _defaultRejoinBackoff(int attempt) {
    const steps = <int>[5, 15, 45, 60];
    return Duration(seconds: steps[attempt.clamp(0, steps.length - 1)]);
  }
  final Future<void> Function(Client client) _pinger;

  static Future<void> _defaultPing(Client client) async {
    try {
      await client.ping(
        options: const RequestOptions(timeout: Duration(seconds: 15)),
      );
    } on McpError catch (e) {
      // A server that says "no such method" is there and answering.
      if (e.code != -32601) rethrow;
    }
  }

  final Map<String, HubLink> _links = <String, HubLink>{};
  final Set<String> _selected = <String>{};
  final StreamController<void> _changed = StreamController<void>.broadcast();
  bool _disposed = false;

  /// Fires whenever a link's state or tool list changes.
  Stream<void> get changes => _changed.stream;

  Iterable<HubLink> get links => _links.values;

  /// Hubs the account may join; [publisher] narrows to one service by name.
  Future<List<HubChoice>> available({String? publisher}) =>
      _market.hubs(publisher: publisher);

  /// Connect the given hubs, or all that the market lists. Every hub gets its
  /// own session; a refused or unreachable hub is recorded as `failed` with
  /// its reason and the rest still connect.
  Future<List<HubLink>> connect({
    List<HubChoice>? choices,
    bool all = false,
    String? publisher,
  }) async {
    final known = <String, HubChoice>{};
    final List<HubChoice> picked;
    if (all) {
      picked = await _market.hubs(publisher: publisher);
    } else {
      picked = choices ?? const <HubChoice>[];
    }
    for (final c in picked) {
      known[c.listingId] = c;
    }
    final outcomes = await _market.connect(
      listingIds: all ? null : known.keys.toList(),
      all: all,
      publisher: publisher,
    );
    final result = <HubLink>[];
    await Future.wait(
      outcomes.map((o) async {
        final choice = known[o.listingId];
        final link = _links.putIfAbsent(
          o.listingId,
          () => HubLink._(
            o.listingId,
            choice?.title ?? o.listingId,
            _namespaceFor(choice?.title ?? o.listingId, o.listingId),
          ),
        );
        _selected.add(o.listingId);
        result.add(link);
        if (o.grant == null) {
          _fail(
            link,
            '${o.errorCode ?? 'hub.refused'}: '
            '${o.errorMessage ?? 'the market refused this hub'}',
          );
          return;
        }
        await _attach(link, o.grant!);
      }),
    );
    return result;
  }

  /// Connect one server the hub lets in without the market (a hub token).
  /// [grant] asks the hub for a session and is called again on every rejoin;
  /// [first] is a session already in hand. A refusal is recorded on the link
  /// as its reason and the link is returned either way.
  Future<HubLink> connectGranted({
    required String id,
    required String title,
    required Future<HubGrant> Function() grant,
    HubGrant? first,
  }) async {
    final link = _links.putIfAbsent(
      id,
      () => HubLink._(id, title, _namespaceFor(title, id)),
    );
    link._regrant = grant;
    _selected.add(id);
    try {
      await _attach(link, first ?? await grant());
    } catch (e) {
      _fail(link, 'hub.refused: $e');
    }
    return link;
  }

  /// The link of [id], if one exists.
  HubLink? linkOf(String id) => _links[id];

  /// Limit which connected hubs expose tools ("only these"). Others stay
  /// connected but invisible to the model.
  void select(Iterable<String> listingIds) {
    _selected
      ..clear()
      ..addAll(listingIds);
    _notify();
  }

  /// Drop one hub: its session closes and its tools disappear.
  Future<void> disconnect(String listingId) async {
    final link = _links.remove(listingId);
    _selected.remove(listingId);
    if (link != null) {
      link._gen++;
      await _teardown(link, HubLinkState.closed);
    }
    _notify();
  }

  Future<void> disconnectAll() async {
    for (final id in _links.keys.toList()) {
      await disconnect(id);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await disconnectAll();
    await _changed.close();
  }

  /// Tools of the selected, connected hubs. Hubs that are not selected, still
  /// connecting or failed contribute nothing.
  Future<List<HubToolRef>> tools() async {
    final out = <HubToolRef>[];
    for (final link in _links.values) {
      if (!_selected.contains(link.listingId)) continue;
      if (link.state != HubLinkState.connected || link._client == null) {
        continue;
      }
      final listed = await link._client!.listTools();
      for (final t in listed) {
        out.add(
          HubToolRef(
            name: '${link.namespace}.${t.name}',
            link: link,
            remoteName: t.name,
            description: t.description,
            inputSchema: t.inputSchema,
          ),
        );
      }
    }
    return out;
  }

  /// Call a namespaced tool. A hub that is reconnecting makes the call wait;
  /// if it does not come back in time the call fails with a clear error —
  /// never silence. The relay delivers at most once, so a call that was cut
  /// mid-flight is reported, not retried: reads are the caller's to retry,
  /// writes need the user's say.
  Future<CallToolResult> call(String name, Map<String, dynamic> args) async {
    final link = _linkOf(name);
    if (link == null) {
      throw HubConnectionError(
        'hub.unknown_tool',
        'no connected hub serves $name',
      );
    }
    if (!_selected.contains(link.listingId)) {
      throw HubConnectionError(
        'hub.not_selected',
        '${link.title} is connected but not selected',
      );
    }
    if (link.state == HubLinkState.reconnecting ||
        link.state == HubLinkState.connecting) {
      try {
        await link._ready.future.timeout(reconnectWait);
      } on TimeoutException {
        throw HubConnectionError(
          'hub.reconnecting',
          '${link.title} is reconnecting; try again shortly',
        );
      }
    }
    final client = link._client;
    if (link.state != HubLinkState.connected || client == null) {
      throw HubConnectionError(
        'hub.unavailable',
        '${link.title} is ${link.state.name}: ${link.error ?? ''}',
      );
    }
    final remote = name.substring(link.namespace.length + 1);
    try {
      final wait = callTimeout;
      return await client.callTool(
        remote,
        args,
        options: wait == null ? null : RequestOptions(timeout: wait),
      );
    } catch (e) {
      throw HubConnectionError('hub.call_failed', '${link.title}: $e');
    }
  }

  HubLink? _linkOf(String name) {
    for (final link in _links.values) {
      if (name.startsWith('${link.namespace}.')) return link;
    }
    return null;
  }

  String _namespaceFor(String title, String listingId) {
    var base = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (base.isEmpty) base = 'hub';
    var ns = base;
    var i = 2;
    while (_links.values.any(
      (l) => l.namespace == ns && l.listingId != listingId,
    )) {
      ns = '${base}_$i';
      i++;
    }
    return ns;
  }

  Future<void> _attach(HubLink link, HubGrant grant) async {
    final gen = ++link._gen;
    await _teardown(link, HubLinkState.connecting, keepReady: true);
    link.error = null;
    HubChannel? opened;
    // Another attach, a disconnect or a dispose may overtake this one while
    // it is awaiting the relay; what it opened then belongs to nobody and
    // must be closed here, or it stays on the hub as an orphan session.
    bool stale() =>
        link._gen != gen || _disposed || _links[link.listingId] != link;
    try {
      final raw = await _open(grant);
      final channel = opened = HubChannel(
        incoming: raw.incoming.map((m) {
          link._heard = DateTime.now();
          try {
            clientSetup?.onFrame?.call(m);
          } catch (_) {}
          return m;
        }),
        send: raw.send,
        close: raw.close,
        done: raw.done,
      );
      final plain = grant.plainMcp;
      final consumer =
          plain
              ? null
              : (HubGatewayConsumer(
                incoming: channel.incoming,
                send: channel.send,
              )..start());
      final setup = clientSetup;
      final client = Client(
        name: clientName,
        version: '1.0.0',
        capabilities: setup?.declared ?? const ClientCapabilities(),
      );
      setup?.configure(client);
      final listed = await () async {
        await client.connect(
          plain ? PlainMcpTransport(channel) : HubConsumerTransport(consumer!),
        );
        return client.listTools();
      }().timeout(handshakeTimeout);
      if (stale()) {
        try {
          client.disconnect();
        } catch (_) {}
        await consumer?.close();
        await channel.close();
        return;
      }
      link
        .._channel = channel
        .._consumer = consumer
        .._client = client
        ..toolNames = [for (final t in listed) t.name]
        ..state = HubLinkState.connected;
      if (!link._ready.isCompleted) link._ready.complete();
      link._renew = Timer(renewAfter, () {
        if (link._gen == gen) _reconnect(link, 'grant renewal');
      });
      link._misses = 0;
      link._retries = 0;
      link._heard = DateTime.now();
      final silence = setup?.serverSilence;
      if (silence != null) {
        link._quiet = Timer.periodic(silence ~/ 4, (_) {
          if (link._gen != gen || link.state != HubLinkState.connected) return;
          if (DateTime.now().difference(link._heard) > silence) {
            _reconnect(link, 'hub.node_lost: the server went silent');
          }
        });
      }
      final every = keepAlive;
      if (every != null) {
        link._keep = Timer.periodic(every, (_) async {
          if (link._gen != gen || link.state != HubLinkState.connected) return;
          try {
            await _pinger(client);
            link._misses = 0;
          } catch (_) {
            if (link._gen == gen && ++link._misses >= 2) {
              _reconnect(link, 'hub.node_lost: the server stopped answering');
            }
          }
        });
      }
      unawaited(
        channel.done.then(
          (_) {
            if (link._gen == gen) _reconnect(link, 'relay closed');
          },
          onError: (Object e) {
            if (link._gen == gen) _reconnect(link, 'relay error: $e');
          },
        ),
      );
      _notify();
    } catch (e) {
      try {
        await opened?.close();
      } catch (_) {}
      if (stale()) return;
      _fail(link, 'hub.connect_failed: $e');
    }
  }

  Future<void> _reconnect(HubLink link, String reason) async {
    if (_disposed || _links[link.listingId] != link) return;
    if (link.state == HubLinkState.reconnecting ||
        link.state == HubLinkState.closed) {
      return;
    }
    link
      ..state = HubLinkState.reconnecting
      ..error = reason;
    if (link._ready.isCompleted) link._ready = Completer<void>();
    _notify();
    try {
      final regrant = link._regrant;
      if (regrant != null) {
        await _attach(link, await regrant());
        return;
      }
      final outcomes = await _market.connect(listingIds: [link.listingId]);
      final o = outcomes.firstWhere((x) => x.listingId == link.listingId);
      if (o.grant == null) {
        _fail(link, '${o.errorCode}: ${o.errorMessage}');
        return;
      }
      await _attach(link, o.grant!);
    } catch (e) {
      _fail(link, 'hub.reconnect_failed: $e');
    }
  }

  void _fail(HubLink link, String reason) {
    link
      ..state = HubLinkState.failed
      ..error = reason;
    // A hub the person opened keeps being tried again, whether it dropped
    // or never opened (relay briefly unavailable); the reason stays on the
    // link. Only disconnect or dispose ends it.
    if (!_disposed && _links[link.listingId] == link) {
      link._retry?.cancel();
      link._retry = Timer(rejoinBackoff(link._retries++), () {
        if (_disposed || _links[link.listingId] != link) return;
        if (link.state == HubLinkState.failed) {
          _reconnect(link, 'retry after: ${link.error}');
        }
      });
    }
    if (!link._ready.isCompleted) {
      link._ready.completeError(HubConnectionError('hub.unavailable', reason));
      // Nobody may be awaiting yet; a failed link is reported through state.
      link._ready.future.catchError((Object _) {});
    }
    _notify();
  }

  Future<void> _teardown(
    HubLink link,
    HubLinkState next, {
    bool keepReady = false,
  }) async {
    link._renew?.cancel();
    link._renew = null;
    link._keep?.cancel();
    link._keep = null;
    link._quiet?.cancel();
    link._quiet = null;
    link._retry?.cancel();
    link._retry = null;
    final client = link._client;
    final consumer = link._consumer;
    final channel = link._channel;
    link
      .._client = null
      .._consumer = null
      .._channel = null
      ..state = next;
    try {
      client?.disconnect();
    } catch (_) {}
    await consumer?.close();
    await channel?.close();
    if (!keepReady && !link._ready.isCompleted) {
      link._ready.completeError(
        const HubConnectionError('hub.closed', 'the hub connection closed'),
      );
      link._ready.future.catchError((Object _) {});
    }
  }

  void _notify() {
    if (!_changed.isClosed) _changed.add(null);
  }
}
