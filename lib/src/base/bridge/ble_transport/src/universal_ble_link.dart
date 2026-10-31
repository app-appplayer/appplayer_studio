// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_transport/lib/src/universal_ble_link.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'ble_link.dart';
import 'ble_uuids.dart';

/// [BleLink] over universal_ble (BSD-3-Clause) — the only file in this
/// recipe that touches the radio plugin. Resolves the fixed MCP Serving
/// GATT service on the connected
/// device. universal_ble covers Android / iOS / macOS / Windows / Linux /
/// Web with one API.
class UniversalBleLink implements BleLink {
  /// [deviceId] is the platform device identifier, e.g.
  /// `BleBoardCandidate.deviceId` from a scan.
  UniversalBleLink({
    required String deviceId,
    Duration connectTimeout = const Duration(seconds: 15),
    Duration scanLocateTimeout = const Duration(seconds: 10),
    Duration setupTimeout = const Duration(seconds: 20),
    BleLocate? locate,
  })  : _deviceId = deviceId,
        _connectTimeout = connectTimeout,
        _setupTimeout = setupTimeout,
        _scanLocateTimeout = scanLocateTimeout,
        _locate = locate;

  /// How the device id gets made known to the radio stack before
  /// connect-by-id (see [_locateByScan]).
  ///
  /// Left null, this link runs its own scan on the global radio —
  /// `UniversalBle.startScan` / `stopScan` are PROCESS-GLOBAL, so the stop that
  /// ends it silences whatever else was scanning, and that owner is never told
  /// and never restarts. Opening one board therefore killed the discovery axis
  /// and any bundle holding `ble://scan`, every time.
  ///
  /// A host that owns one radio passes its own locator and nothing here
  /// touches the global scan.
  final BleLocate? _locate;

  final String _deviceId;
  final Duration _connectTimeout;

  /// Budget for each step that sets the link up after connect — service
  /// discovery, MTU, the notification subscription. universal_ble bounds every
  /// command at ten seconds unless told otherwise, and an Android tablet's
  /// first GATT service discovery of a board ran past that (measured
  /// 2026-10-03: the first open failed at 10.0 s, the next took 1.6 s once
  /// the services were cached).
  final Duration _setupTimeout;

  /// Budget for the fallback scan that registers a device id universal_ble has
  /// not seen yet (see [connect]).
  final Duration _scanLocateTimeout;

  final _disconnected = Completer<void>();

  StreamSubscription<bool>? _connectionSub;
  bool _resolved = false;
  bool _writeWithoutResponse = false;

  /// Disconnects still in flight, by device id. A transport's `close` does
  /// not wait for the radio to let go, so the next link to the same board
  /// (the open that follows a discovery probe, a refresh that follows a page)
  /// started its connect while the last one was still being torn down, and
  /// stalled until its timeout (measured 2026-10-04: the first open after a
  /// probe timed out at 20 s, the retry connected in 4 s).
  static final Map<String, Future<void>> _releasing = <String, Future<void>>{};

  /// How long a connect waits for the previous link to the board to go.
  static const Duration _releaseWait = Duration(seconds: 5);

  /// When each board was last let go. A connect within a moment of that
  /// failed on an Android 10 tablet — 36 ms after a probe let go, the next
  /// connect's GATT client had no connection on record; the reconnect a second
  /// later succeeded (measured 2026-10-04).
  static final Map<String, DateTime> _releasedAt = <String, DateTime>{};
  static const Duration _reconnectGap = Duration(seconds: 1);

  Future<void> _awaitGap() async {
    final at = _releasedAt[_deviceId];
    if (at == null) return;
    final wait = _reconnectGap - DateTime.now().difference(at);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  Future<void> _radioDisconnect() async {
    try {
      await UniversalBle.disconnect(_deviceId);
    } finally {
      _releasedAt[_deviceId] = DateTime.now();
    }
  }

  @override
  Future<void> connect() async {
    final releasing = _releasing[_deviceId];
    if (releasing != null) {
      try {
        await releasing.timeout(_releaseWait);
      } catch (_) {
        // Proceed: a release that does not finish is not this connect's to
        // wait on forever.
      }
    }
    await _awaitGap();
    try {
      await UniversalBle.connect(_deviceId, timeout: _connectTimeout);
    } catch (_) {
      // Connecting by device id needs universal_ble to have the peripheral in
      // its registry, which only an advertisement populates. Opening a saved
      // board straight from the launcher has seen none, so the very first
      // connect fails (deviceNotFound / unknown deviceId) even though the
      // board is right there advertising. Wait for it to be seen, then retry
      // once. (The discovery/probe path is already watching, which is why it
      // never hit this.)
      //
      // Without a locator there is no recovery: this link will NOT scan on its
      // own. `startScan`/`stopScan` are process-global, so doing that would
      // silence whatever else is watching, and the owner is never told and
      // never restarts. A connect that cannot be recovered reports the connect
      // failure — which is the truth — instead of trading someone else's
      // observation for it.
      final host = _locate;
      if (host == null) rethrow;
      await host(_deviceId, _scanLocateTimeout);
      await _awaitGap();
      try {
        await UniversalBle.connect(_deviceId, timeout: _connectTimeout);
      } catch (_) {
        // A connect given up on here can still complete in the radio stack;
        // withdraw it so the board is not left held by this phone.
        await _releaseQuietly();
        rethrow;
      }
    }

    _connectionSub = UniversalBle.connectionStream(_deviceId)
        .where((connected) => !connected)
        .listen((_) => _completeDisconnected());

    final List<BleService> services;
    try {
      services = await _discoverServices();
    } catch (_) {
      // Connected but not set up: let the board go. A board held by a phone
      // that stopped using it does not advertise, so nobody finds it again.
      await _releaseQuietly();
      rethrow;
    }
    final serviceUuid = BleUuidParser.string(mcpBleServiceUuid);
    final matches = services.where((s) => s.uuid == serviceUuid);
    if (matches.isEmpty) {
      await disconnect();
      throw StateError(
        'MCP Serving service $mcpBleServiceUuid not found on '
        '$_deviceId — not an MCP-serving board?',
      );
    }

    final characteristics = matches.first.characteristics;
    final rx = _findCharacteristic(characteristics, mcpBleRxCharUuid);
    final tx = _findCharacteristic(characteristics, mcpBleTxCharUuid);
    if (rx == null || tx == null) {
      await disconnect();
      throw StateError(
        'MCP Serving service on $_deviceId is missing its RX/TX '
        'characteristics (conformance failure)',
      );
    }
    // The server accepts both write modes; Write Without Response
    // is preferred for throughput when the characteristic offers it.
    _writeWithoutResponse =
        rx.properties.contains(CharacteristicProperty.writeWithoutResponse);
    _resolved = true;
  }

  /// Service discovery, with one fresh link if the first goes unanswered.
  ///
  /// On an Android 10 tablet the radio stack sometimes reports the link up
  /// while its GATT service has no connection on record for this client; every
  /// discovery asked on that link is refused ("discoverServices() - No
  /// connection") and never answered — asking again on the same link failed
  /// three times out of three. A fresh link answered (measured 2026-10-04). So
  /// one short ask, and if it goes unanswered: let the link go, connect again,
  /// ask once more with the rest of the setup budget.
  Future<List<BleService>> _discoverServices() async {
    final deadline = DateTime.now().add(_setupTimeout);
    await Future<void>.delayed(_discoverySettle);
    try {
      return await UniversalBle.discoverServices(
        _deviceId,
        timeout: _firstDiscoveryTimeout,
      );
    } catch (_) {
      // Fall through to a fresh link.
    }
    // Only the radio link goes; this link's own life (its disconnected
    // signal, which the transport above watches) carries on to the fresh one.
    await _connectionSub?.cancel();
    _connectionSub = null;
    try {
      await _radioDisconnect();
    } catch (_) {}
    await _awaitGap();
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) {
      throw TimeoutException('service discovery', _setupTimeout);
    }
    await UniversalBle.connect(_deviceId, timeout: left);
    _connectionSub = UniversalBle.connectionStream(_deviceId)
        .where((connected) => !connected)
        .listen((_) => _completeDisconnected());
    await Future<void>.delayed(_discoverySettle);
    final rest = deadline.difference(DateTime.now());
    if (rest <= Duration.zero) {
      throw TimeoutException('service discovery', _setupTimeout);
    }
    return UniversalBle.discoverServices(_deviceId, timeout: rest);
  }

  static const Duration _discoverySettle = Duration(milliseconds: 500);
  static const Duration _firstDiscoveryTimeout = Duration(seconds: 4);

  Future<void> _releaseQuietly() async {
    try {
      await disconnect();
    } catch (_) {
      // Already gone.
    }
  }

  BleCharacteristic? _findCharacteristic(
    List<BleCharacteristic> characteristics,
    String uuid,
  ) {
    final normalized = BleUuidParser.string(uuid);
    for (final c in characteristics) {
      if (c.uuid == normalized) return c;
    }
    return null;
  }

  @override
  Future<int> requestMtu(int desired) {
    // Best-effort per platform (Android honors the request; iOS/macOS/
    // Windows/Linux auto-negotiate and only report). Returns the effective
    // MTU; if the platform cannot even report one this throws and the
    // transport falls back to the default ATT MTU 23.
    return UniversalBle.requestMtu(_deviceId, desired, timeout: _setupTimeout);
  }

  @override
  Future<Stream<List<int>>> subscribeTxNotifications() async {
    if (!_resolved) {
      throw StateError('not connected — call connect() first');
    }
    // CCCD write (the server sends nothing before this).
    await UniversalBle.subscribeNotifications(
      _deviceId,
      mcpBleServiceUuid,
      mcpBleTxCharUuid,
      timeout: _setupTimeout,
    );
    return UniversalBle.characteristicValueStream(
      _deviceId,
      mcpBleTxCharUuid,
    );
  }

  @override
  Future<void> writeRxChunk(List<int> chunk) async {
    if (!_resolved) {
      throw StateError('not connected — call connect() first');
    }
    await UniversalBle.write(
      _deviceId,
      mcpBleServiceUuid,
      mcpBleRxCharUuid,
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
      withoutResponse: _writeWithoutResponse,
    );
  }

  @override
  Future<void> get onDisconnected => _disconnected.future;

  @override
  Future<void> disconnect() async {
    final release = _radioDisconnect();
    _releasing[_deviceId] = release;
    try {
      await release;
    } finally {
      if (identical(_releasing[_deviceId], release)) {
        _releasing.remove(_deviceId);
      }
      _completeDisconnected();
    }
  }

  void _completeDisconnected() {
    if (!_disconnected.isCompleted) _disconnected.complete();
    _connectionSub?.cancel();
    _connectionSub = null;
  }
}
