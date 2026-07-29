/// Orchestrates the local-server feature: connect + metadata capture, the
/// Home INSTALLED APPS tiles, tile open (reconnect from the keychain +
/// render), and removal.
///
/// Install = connect + read the served app's `ui://app` metadata (for the
/// tile label) — NOT render. Execution (rendering the served app as a tab) is
/// the tile tap. Connections are in-memory, so a tap after a restart resolves
/// the access token from the keychain vault and replays the connect before
/// mounting the tab.
library;

import 'package:flutter/material.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../main/studio_workspace.dart' show HomeInstalledTile;
import 'connect_server_dialog.dart' show ConnectServerRequest;
import 'local_server_store.dart';
import 'served_service.dart';

/// Opens an extension tab with a custom body (the host's chrome seam).
typedef OpenServerTab =
    void Function({
      required String key,
      required String label,
      required WidgetBuilder builder,
    });

class LocalServerManager {
  LocalServerManager({
    required mk.KernelClientHost clientHost,
    required LocalServerStore store,
    required LocalServerCredentialVault vault,
    required OpenServerTab openTab,
    ValueNotifier<int>? themeReinjectTick,
  })  : _clientHost = clientHost,
        _store = store,
        _vault = vault,
        _openTab = openTab,
        _themeReinjectTick = themeReinjectTick;

  final mk.KernelClientHost _clientHost;
  final LocalServerStore _store;
  final LocalServerCredentialVault _vault;
  final OpenServerTab _openTab;
  final ValueNotifier<int>? _themeReinjectTick;

  bool _isLive(String id) =>
      _clientHost.connections.any((c) => c.id == id && c.isConnected);

  /// Raw kernel connect, shaped per transport (stdio → command/args; HTTP/SSE →
  /// endpoint + optional bearer token).
  Future<void> _connectRaw({
    required String id,
    required mk.KernelTransportKind transport,
    String? endpoint,
    String? command,
    List<String> args = const <String>[],
    String? accessToken,
  }) {
    if (transport == mk.KernelTransportKind.stdio) {
      return _clientHost.connect(
        id: id,
        transport: transport,
        options: <String, dynamic>{'command': command, 'args': args},
      );
    }
    return _clientHost.connect(
      id: id,
      transport: transport,
      endpoint: endpoint,
      options: <String, dynamic>{
        if (accessToken != null) 'accessToken': accessToken,
      },
    );
  }

  /// Connect a newly-added local server: establish the connection, capture the
  /// served app's title for the tile (metadata-only — no render), stash any
  /// token in the keychain, and record it. Throws on connect failure so the
  /// caller can surface it.
  Future<void> connect(ConnectServerRequest req) async {
    final id = req.transport == mk.KernelTransportKind.stdio
        ? req.command!
        : req.endpoint!;
    await _connectRaw(
      id: id,
      transport: req.transport,
      endpoint: req.endpoint,
      command: req.command,
      args: req.args,
      accessToken: req.accessToken,
    );

    // Metadata-only: read the served app's own title for the tile label.
    // Best-effort — a server without `ui://app` keeps the fallback name.
    String label = req.name ?? id;
    try {
      final conn = liveServiceConnection(_clientHost, id);
      final app = await readServiceJson(conn, 'ui://app');
      final served = app['title'];
      if (req.name == null && served is String && served.isNotEmpty) {
        label = served;
      }
    } catch (_) {
      /* keep fallback label */
    }

    // Only HTTP carries a bearer token worth persisting (stdio is a local
    // process; SSE connect takes no token).
    String? credentialRef;
    if (req.transport == mk.KernelTransportKind.streamableHttp &&
        req.accessToken != null) {
      credentialRef = LocalServerCredentialVault.refFor(id);
      await _vault.write(credentialRef, req.accessToken!);
    }
    _store.put(
      LocalServerRecord(
        id: id,
        transport: req.transport,
        name: label,
        endpoint: req.endpoint,
        command: req.command,
        args: req.args,
        credentialRef: credentialRef,
      ),
    );
  }

  /// Open the served app of an already-live connection [id] as a tab — used
  /// for discovered boards (connected through the extension / BLE seam) that
  /// aren't recorded local servers. [title] labels the tab (falls back to the
  /// connection id). No reconnect: the caller connected it moments ago; if it
  /// drops, [ServedServiceBody] surfaces the error + Retry.
  void openServed(String id, {String? title}) {
    _openTab(
      key: 'local-server:$id',
      label: title ?? id,
      builder: (_) => ServedServiceBody(
        clientHost: _clientHost,
        connectionId: id,
        themeReinjectTick: _themeReinjectTick,
      ),
    );
  }

  /// The Home INSTALLED APPS tiles for every recorded local server.
  List<HomeInstalledTile> tiles() {
    return <HomeInstalledTile>[
      for (final r in _store.list())
        HomeInstalledTile(
          label: r.name,
          icon: Icons.dns_outlined,
          onOpen: () => _open(r),
          onRemove: () => _remove(r),
        ),
    ];
  }

  /// Open a local server's served app as a tab. In-memory connections do not
  /// survive a restart, so reconnect (from the keychain token for HTTP) first
  /// when the connection is not live. Reconnect is best-effort — the tab opens
  /// either way and [ServedServiceBody] surfaces an actionable error + Retry
  /// when the connection is down, rather than a silent no-op.
  Future<void> _open(LocalServerRecord r) async {
    try {
      await reopen(r.id);
    } catch (_) {
      /* tab still opens; the body shows the error + Retry */
    }
    _openTab(
      key: 'local-server:${r.id}',
      label: r.name,
      builder: (_) => ServedServiceBody(
        clientHost: _clientHost,
        connectionId: r.id,
        themeReinjectTick: _themeReinjectTick,
      ),
    );
  }

  /// Re-establish the connection for a recorded server WITHOUT opening a tab.
  ///
  /// This is the composition `openOrigin` path: a composed document NAMES an
  /// origin, and the host opens it on FIRST USE. Registered devices are
  /// deliberately not held open — several boards serve a single peer at a time,
  /// so a permanent connection per registered device has the last one to
  /// connect reset the others (`Connection reset by peer`, measured on the
  /// bench), and the tiles on screen then die in turn.
  ///
  /// Already live → no-op, so a second reference to the same origin in one
  /// document does not re-open it. Unknown id → no-op, and the caller surfaces
  /// "origin is not connected" rather than this silently substituting another.
  /// No transport discrimination: whatever [_connectRaw] can open, this opens.
  Future<void> reopen(String id) async {
    if (_isLive(id)) return;
    final r = _store.list().where((e) => e.id == id).firstOrNull;
    if (r == null) return;
    final token =
        r.credentialRef == null ? null : await _vault.read(r.credentialRef!);
    await _connectRaw(
      id: r.id,
      transport: r.transport,
      endpoint: r.endpoint,
      command: r.command,
      args: r.args,
      accessToken: token,
    );
  }

  Future<void> _remove(LocalServerRecord r) async {
    // Best-effort teardown of the live session (the host has no per-id
    // disconnect — close the matching connection directly).
    final conn = _clientHost.connections.where((c) => c.id == r.id).firstOrNull;
    if (conn != null) {
      try {
        await conn.close();
      } catch (_) {
        /* already gone */
      }
    }
    if (r.credentialRef != null) {
      await _vault.delete(r.credentialRef!);
    }
    _store.remove(r.id);
  }
}
