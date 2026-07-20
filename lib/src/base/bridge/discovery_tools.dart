/// Board discovery — Studio-owned wiring over the vendored
/// `device_discovery` (spec 17, two-stage discovery) and `ble_transport`
/// (spec 16, BLE GATT) recipes.
///
/// Discovery is exposed MCP-first (Studio is LLM-driven):
/// - `mcp.discover_boards {source: mdns|ble|usb|directory}` — one scan
///   window, returns candidates. mdns ndjson / usb serial / directory
///   `tcp://` candidates are Stage-2 probe-CONFIRMED before they are
///   reported (probe failure drops the candidate — it is not a conforming
///   MCP node); `http(s)` endpoints are reported unprobed (`probed:
///   false`, they attach like any remote MCP server).
/// - `mcp.connect_ble_board {deviceId}` — spec 16 connection sequence over
///   the real radio, injected through the kernel extension seam. A
///   discovered TCP/serial board needs no new tool: connect it with the
///   existing `mcp.connect_extension` per the candidate's `connectHint`.
/// - [StudioDiscovery.sweep] — the settings-driven boot sweep (Auto
///   discovery section): scans the enabled non-BLE sources and, when the
///   auto-connect policy is on, connects confirmed boards through the same
///   seam (id `board:<manifest id>`). BLE is excluded from the sweep — its
///   first scan raises the OS Bluetooth permission prompt, which must come
///   from a user action, not from boot.
///
/// The radio / network / enumeration seams are injectable so tests run
/// against fakes; the defaults are the real ones.
library;

import 'dart:async';

import 'package:brain_kernel/brain_kernel.dart'
    show HostToolRegistry, KernelClientHost, wrapInProcess;
import 'package:brain_kernel/mcp_host.dart' show connectExtension;
import 'package:clib_serialport_dart/clib_serialport_dart.dart' as csp;
import 'package:mcp_bridge/mcp_bridge.dart'
    show SerialClientTransport, TcpClientTransport;
import 'package:mcp_client/mcp_client.dart' show ClientTransport;

import 'ble_transport/ble_transport.dart';
import 'device_discovery/device_discovery.dart';
import 'discovery_trust.dart';

// The pieces of the vendored recipes a host touches directly (the LDAP
// source config + the probe identity) surface through this wiring module —
// hosts never import the vendored trees themselves.
export 'device_discovery/device_discovery.dart'
    show BoardIdentity, DirectoryConfig;

/// Default scan window per `mcp.discover_boards` call.
const Duration kDiscoverScanTimeout = Duration(seconds: 5);

/// Ceiling for one Stage-2 probe (per candidate).
const Duration kDiscoverProbeTimeout = Duration(seconds: 5);

/// Board serial wire default (embedded serial binding: 115200-8N1).
const int kDiscoverSerialBaudRate = 115200;

/// One enumerated serial port (usb source Stage 1 — the physical
/// connection IS the announcement; every port is a candidate, VID/PID is
/// never a filter. The probe is the gate, spec 17 §2).
typedef SerialPortCandidate = ({String portName, String description});

/// Probe seam — [probeCandidate] signature, injectable for tests.
typedef ProbeFn = Future<BoardIdentity?> Function({
  required FutureOr<ClientTransport> Function() buildTransport,
  Duration timeout,
  String clientName,
  String clientVersion,
});

/// Manifest trust seam (spec 17 §6, [ManifestTrustEvaluator.evaluate]).
/// Null = trust verification not wired (candidates carry no `trust` field and
/// signature enforcement is inert). Injected by the host once its root-CA
/// trust anchor is provisioned.
typedef TrustEvidenceFn = Future<TrustEvidence?> Function(BoardIdentity);

/// Register `mcp.discover_boards` + `mcp.connect_ble_board` and hand back
/// the [StudioDiscovery] surface (tool names + the settings-driven sweep).
///
/// Seams default to the real network/radio/OS; tests inject fakes.
/// [directoryConfig] supplies the LDAP source config (host reads it fresh
/// from settings per call); null/`null`-returning = directory source
/// unconfigured.
StudioDiscovery registerDiscoveryTools(
  HostToolRegistry registry,
  KernelClientHost? clientHost, {
  MdnsBoardScanner? mdnsScanner,
  BleBoardScanner? bleScanner,
  DirectoryBoardScanner? directoryScanner,
  List<SerialPortCandidate> Function()? enumerateSerialPorts,
  FutureOr<DirectoryConfig?> Function()? directoryConfig,
  ProbeFn? probe,
  BleLink Function(String deviceId)? bleLinkFor,
  // Trust verification seam (spec 17 §6). [trustEvaluator] attaches signature
  // evidence to probe-confirmed candidates; [enforceSignature] (read fresh from
  // settings per call) gates the auto-connect sweep and connectCandidate on it.
  // Both default off so discovery behaves exactly as before until the host
  // wires a trust anchor.
  TrustEvidenceFn? trustEvaluator,
  FutureOr<bool> Function()? enforceSignature,
}) {
  final discovery = StudioDiscovery._(
    clientHost: clientHost,
    mdns: mdnsScanner ?? MdnsBoardScanner(),
    ble: bleScanner ?? BleBoardScanner(),
    directory: directoryScanner ?? DirectoryBoardScanner(),
    enumeratePorts: enumerateSerialPorts ??
        () => csp
            .listSerialPorts()
            .map(
              (info) => (portName: info.name, description: info.description),
            )
            .toList(growable: false),
    directoryConfig: directoryConfig ?? () => null,
    probe: probe ?? probeCandidate,
    bleLinkFor: bleLinkFor,
    trustEvaluator: trustEvaluator,
    enforceSignature: enforceSignature,
  );

  discovery._toolNames.addAll(<String>[
    registry.registerExposed(
      bundleId: 'mcp',
      rawName: 'discover_boards',
      description:
          'Discover nearby MCP-serving boards. source=mdns browses '
          '`_mcp._tcp` on the LAN; source=usb probes every serial port; '
          'source=directory searches the configured LDAP for labeledURI '
          'endpoints; source=ble scans by the MCP Serving service UUID '
          '(triggers the OS Bluetooth permission on first use). '
          'mdns/usb/directory candidates are probe-confirmed (manifest '
          'read) before they are reported. Each candidate carries a '
          'connectHint (mcp.connect_extension / mcp.connect_ble_board).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'source': <String, dynamic>{
            'type': 'string',
            'enum': <String>['mdns', 'ble', 'usb', 'directory'],
          },
          'timeoutSeconds': <String, dynamic>{
            'type': 'number',
            'description': 'Scan window (default 5s).',
          },
        },
        'required': <String>['source'],
      },
      handler: wrapInProcess(discovery._discoverTool),
    ),
    registry.registerExposed(
      bundleId: 'mcp',
      rawName: 'connect_ble_board',
      description:
          'Connect to a BLE MCP-serving board discovered by '
          'mcp.discover_boards (spec 16 GATT sequence), injecting the '
          'connection through the kernel seam. Drive it afterward with '
          'mcp.list_tools / mcp.call_tool / mcp.read_resource / '
          'mcp.disconnect.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'deviceId': <String, dynamic>{'type': 'string'},
          'id': <String, dynamic>{
            'type': 'string',
            'description': "Connection id (default 'ble:<deviceId>').",
          },
        },
        'required': <String>['deviceId'],
      },
      handler: wrapInProcess(discovery._connectBleTool),
    ),
  ]);
  return discovery;
}

/// The discovery surface a host keeps after registration — exposed tool
/// names plus the settings-driven [sweep].
class StudioDiscovery {
  StudioDiscovery._({
    required this.clientHost,
    required MdnsBoardScanner mdns,
    required BleBoardScanner ble,
    required DirectoryBoardScanner directory,
    required List<SerialPortCandidate> Function() enumeratePorts,
    required FutureOr<DirectoryConfig?> Function() directoryConfig,
    required ProbeFn probe,
    BleLink Function(String deviceId)? bleLinkFor,
    TrustEvidenceFn? trustEvaluator,
    FutureOr<bool> Function()? enforceSignature,
  })  : _mdns = mdns,
        _ble = ble,
        _directory = directory,
        _enumeratePorts = enumeratePorts,
        _directoryConfig = directoryConfig,
        _probe = probe,
        _bleLinkFor = bleLinkFor,
        _trustEvaluator = trustEvaluator,
        _enforceSignature = enforceSignature;

  final KernelClientHost? clientHost;
  final MdnsBoardScanner _mdns;
  final BleBoardScanner _ble;
  final DirectoryBoardScanner _directory;
  final List<SerialPortCandidate> Function() _enumeratePorts;
  final FutureOr<DirectoryConfig?> Function() _directoryConfig;
  final ProbeFn _probe;
  final BleLink Function(String deviceId)? _bleLinkFor;
  final TrustEvidenceFn? _trustEvaluator;
  final FutureOr<bool> Function()? _enforceSignature;
  final List<String> _toolNames = <String>[];

  /// Attach signature evidence (spec 17 §6) to a probe-confirmed [candidate].
  /// No-op when no evaluator is wired (candidate stays untouched). Otherwise a
  /// `trust` map is added: `{signed, verified, partnerChainValid}` — `signed`
  /// distinguishes an unsigned manifest (no `trust` block) from a signed one
  /// that failed verification, `verified` is the connect gate.
  Future<void> _attachTrust(
    Map<String, dynamic> candidate,
    BoardIdentity identity,
  ) async {
    final evaluator = _trustEvaluator;
    if (evaluator == null) return;
    final evidence = await evaluator(identity);
    candidate['trust'] = evidence == null
        ? const <String, dynamic>{'signed': false, 'verified': false}
        : <String, dynamic>{
            'signed': true,
            'verified': evidence.signatureValid,
            'partnerChainValid': evidence.partnerChainValid,
          };
  }

  /// Whether [candidate] may be connected under the current signature policy.
  /// Enforcement off → always allowed. Enforcement on → fail-closed: only a
  /// candidate whose attached evidence verified may connect (an unsigned board,
  /// an unverified signature, or a candidate with no evidence at all is
  /// rejected). BLE candidates carry no pre-connect manifest, so under
  /// enforcement they are blocked until post-connect trust (spec §7) lands.
  Future<bool> _connectAllowedByTrust(Map<String, dynamic> candidate) async {
    final enforce = await _enforceSignature?.call() ?? false;
    if (!enforce) return true;
    final trust = candidate['trust'];
    return trust is Map && trust['verified'] == true;
  }

  /// Names the registration exposed (`mcp.discover_boards`,
  /// `mcp.connect_ble_board`).
  List<String> get toolNames => List<String>.unmodifiable(_toolNames);

  Future<BoardIdentity?> _probeTcp(String host, int port) =>
      _probe(
        buildTransport: () async {
          final t = TcpProbeTransport(host: host, port: port);
          await t.start();
          return t;
        },
        timeout: kDiscoverProbeTimeout,
        clientName: 'studio.discover',
        clientVersion: '0.1.0',
      );

  /// One scan window over [source]; returns the tool-shaped result map.
  Future<Map<String, dynamic>> discover(
    String source, {
    Duration timeout = kDiscoverScanTimeout,
  }) async {
    switch (source) {
      case 'mdns':
        final out = <Map<String, dynamic>>[];
        await for (final c in _mdns.scan(timeout: timeout)) {
          if (c.probeableOverTcp) {
            // Stage 2 — only a confirmed manifest makes it a board.
            final identity = await _probeTcp(c.host, c.port);
            if (identity == null) continue; // non-conformant → dropped
            final candidate = <String, dynamic>{
              'source': 'mdns',
              'name': identity.name,
              'instanceName': c.instanceName,
              'host': c.host,
              'port': c.port,
              'proto': 'ndjson',
              'probed': true,
              'id': identity.id,
              'version': identity.version,
              if (identity.entryPoint != null)
                'entryPoint': identity.entryPoint,
              'connectHint': <String, dynamic>{
                'tool': 'mcp.connect_extension',
                'transport': 'tcp',
                'options': <String, dynamic>{'host': c.host, 'port': c.port},
              },
            };
            await _attachTrust(candidate, identity);
            out.add(candidate);
          } else if (c.txt.proto == MdnsProto.http) {
            // Streamable-HTTP node — outside the TCP probe path; report
            // as-is (attaches like any remote MCP server).
            out.add(<String, dynamic>{
              'source': 'mdns',
              'name': c.instanceName,
              'instanceName': c.instanceName,
              'host': c.host,
              'port': c.port,
              'proto': 'http',
              'probed': false,
              if (c.txt.path != null) 'path': c.txt.path,
              if (c.txt.id != null) 'id': c.txt.id,
              if (c.txt.version != null) 'version': c.txt.version,
            });
          }
          // proto=unknown → non-conformant announcement, dropped (spec 17).
        }
        return <String, dynamic>{
          'ok': true,
          'source': 'mdns',
          'count': out.length,
          'candidates': out,
        };
      case 'ble':
        final seen = <String>{};
        final out = <Map<String, dynamic>>[];
        await for (final c in _ble.scan(timeout: timeout)) {
          if (!seen.add(c.deviceId)) continue;
          out.add(<String, dynamic>{
            'source': 'ble',
            'deviceId': c.deviceId,
            'name': c.localName,
            'rssi': c.rssi,
            'connectHint': <String, dynamic>{
              'tool': 'mcp.connect_ble_board',
              'deviceId': c.deviceId,
            },
          });
        }
        return <String, dynamic>{
          'ok': true,
          'source': 'ble',
          'count': out.length,
          'candidates': out,
        };
      case 'usb':
        // Stage 1 = enumeration (the plug is the announcement); Stage 2 =
        // the same probe-confirm over the board serial wire. Quiet ports
        // never surface — unrelated serial devices are dropped silently.
        final out = <Map<String, dynamic>>[];
        for (final port in _enumeratePorts()) {
          final identity = await _probe(
            buildTransport: () async {
              final t = SerialClientTransport(<String, dynamic>{
                'port': port.portName,
                'baudRate': kDiscoverSerialBaudRate,
              });
              await t.start();
              return t;
            },
            timeout: kDiscoverProbeTimeout,
            clientName: 'studio.discover',
            clientVersion: '0.1.0',
          );
          if (identity == null) continue;
          final candidate = <String, dynamic>{
            'source': 'usb',
            'name': identity.name,
            'portName': port.portName,
            if (port.description.isNotEmpty) 'description': port.description,
            'probed': true,
            'id': identity.id,
            'version': identity.version,
            if (identity.entryPoint != null) 'entryPoint': identity.entryPoint,
            'connectHint': <String, dynamic>{
              'tool': 'mcp.connect_extension',
              'transport': 'serial',
              'options': <String, dynamic>{
                'port': port.portName,
                'baudRate': kDiscoverSerialBaudRate,
              },
            },
          };
          await _attachTrust(candidate, identity);
          out.add(candidate);
        }
        return <String, dynamic>{
          'ok': true,
          'source': 'usb',
          'count': out.length,
          'candidates': out,
        };
      case 'directory':
        final config = await _directoryConfig();
        if (config == null) {
          return <String, dynamic>{
            'ok': false,
            'error':
                'directory source not configured — set host/baseDN in '
                'Settings → Auto discovery.',
          };
        }
        final out = <Map<String, dynamic>>[];
        await for (final c in _directory.scan(config)) {
          final uri = Uri.tryParse(c.endpoint);
          if (uri == null) continue;
          if (uri.scheme == 'tcp') {
            // Same conformance gate as mdns ndjson: only a confirmed
            // manifest makes it a board.
            final identity = await _probeTcp(uri.host, uri.port);
            if (identity == null) continue;
            final candidate = <String, dynamic>{
              'source': 'directory',
              'name': identity.name,
              'endpoint': c.endpoint,
              'probed': true,
              'id': identity.id,
              'version': identity.version,
              if (identity.entryPoint != null)
                'entryPoint': identity.entryPoint,
              'connectHint': <String, dynamic>{
                'tool': 'mcp.connect_extension',
                'transport': 'tcp',
                'options': <String, dynamic>{
                  'host': uri.host,
                  'port': uri.port,
                },
              },
            };
            await _attachTrust(candidate, identity);
            out.add(candidate);
          } else if (uri.scheme == 'http' || uri.scheme == 'https') {
            // Streamable-HTTP node — attaches like any remote MCP server.
            out.add(<String, dynamic>{
              'source': 'directory',
              'name': c.name,
              'endpoint': c.endpoint,
              'probed': false,
            });
          }
          // Other schemes (RFC 2079 labeledURI is free-form) are not MCP
          // endpoints for this host — dropped.
        }
        return <String, dynamic>{
          'ok': true,
          'source': 'directory',
          'count': out.length,
          'candidates': out,
        };
      default:
        return <String, dynamic>{
          'ok': false,
          'error': "source must be 'mdns' | 'ble' | 'usb' | 'directory'",
        };
    }
  }

  /// Settings-driven sweep (Auto discovery): scan the enabled non-BLE
  /// sources once; with [autoConnect] each probe-confirmed candidate is
  /// connected through the kernel seam under `board:<manifest id>`
  /// (already-connected ids are left alone). Returns a report —
  /// `{sources, candidates, connected, skipped, errors}`.
  Future<Map<String, dynamic>> sweep({
    required bool usb,
    required bool mdns,
    required bool directory,
    required bool autoConnect,
    Duration timeout = kDiscoverScanTimeout,
  }) async {
    final sources = <String>[
      if (mdns) 'mdns',
      if (usb) 'usb',
      if (directory) 'directory',
    ];
    final candidates = <Map<String, dynamic>>[];
    final errors = <String>[];
    for (final source in sources) {
      final result = await discover(source, timeout: timeout);
      if (result['ok'] == true) {
        candidates.addAll(
          (result['candidates'] as List).cast<Map<String, dynamic>>(),
        );
      } else {
        errors.add('$source: ${result['error']}');
      }
    }
    final connected = <String>[];
    final skipped = <String>[];
    final blocked = <String>[];
    if (autoConnect) {
      for (final c in candidates) {
        final hint = c['connectHint'];
        final manifestId = c['id'];
        if (hint is! Map || manifestId is! String) continue;
        if (hint['tool'] != 'mcp.connect_extension') continue;
        final id = 'board:$manifestId';
        if (!await _connectAllowedByTrust(c)) {
          // Signature enforced and the board is unsigned / unverified —
          // never auto-connect it (spec 17 §6). Surfaced separately from
          // `skipped` (which is "already live") so the reason is clear.
          blocked.add(id);
          continue;
        }
        final existing = clientHost?.connections
            .where((conn) => conn.id == id && conn.isConnected)
            .firstOrNull;
        if (existing != null) {
          skipped.add(id); // already live — the sweep never reconnects
          continue;
        }
        try {
          final options =
              (hint['options'] as Map).cast<String, dynamic>();
          final ClientTransport transport;
          switch (hint['transport']) {
            case 'tcp':
              final t = TcpClientTransport(options);
              await t.start();
              transport = t;
            case 'serial':
              final t = SerialClientTransport(options);
              await t.start();
              transport = t;
            default:
              continue;
          }
          final conn = await connectExtension(
            clientHost,
            id: id,
            transport: transport,
          );
          if (conn.isConnected) connected.add(id);
        } catch (e) {
          errors.add('$id: $e');
        }
      }
    }
    return <String, dynamic>{
      'sources': sources,
      'candidates': candidates.length,
      'connected': connected,
      'skipped': skipped,
      'blocked': blocked,
      'errors': errors,
    };
  }

  /// Connect a discovered [candidate] (a `candidates` entry from [discover])
  /// through the host, returning the live connection id. TCP / serial
  /// candidates open through the extension seam under `board:<manifest id>`;
  /// BLE candidates get the GATT connect under `ble:<deviceId>`. Both land in
  /// the shared client-host registry, so the connection renders like any other
  /// served app afterward.
  ///
  /// http(s) candidates carry no `connectHint` and are NOT handled here — they
  /// attach as an ordinary streamable-HTTP server (the caller connects them
  /// through the kernel's own client host by endpoint). Throws if the
  /// candidate is not connectable through this seam or the transport fails.
  Future<String> connectCandidate(Map<String, dynamic> candidate) async {
    if (!await _connectAllowedByTrust(candidate)) {
      throw StateError(
        'signature enforcement is on and this board is unsigned or unverified '
        '(spec 17 §6) — sign the board or disable enforcement in '
        'Settings → Auto discovery',
      );
    }
    final hint = candidate['connectHint'];
    if (hint is! Map) {
      throw StateError(
        'candidate carries no connectHint — connect it as a remote server '
        'by endpoint instead',
      );
    }
    final tool = hint['tool'];
    if (tool == 'mcp.connect_ble_board') {
      final deviceId =
          (hint['deviceId'] as String?) ?? (candidate['deviceId'] as String?);
      if (deviceId == null || deviceId.isEmpty) {
        throw StateError('ble candidate has no deviceId');
      }
      final result =
          await _connectBleTool(<String, dynamic>{'deviceId': deviceId});
      if (result['ok'] != true) {
        throw StateError('ble connect failed: ${result['error']}');
      }
      return result['id'] as String;
    }
    if (tool == 'mcp.connect_extension') {
      final manifestId = candidate['id'];
      final options =
          (hint['options'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final id = manifestId is String && manifestId.isNotEmpty
          ? 'board:$manifestId'
          : 'board:${options['host'] ?? options['port'] ?? 'device'}';
      final ClientTransport transport;
      switch (hint['transport']) {
        case 'tcp':
          final t = TcpClientTransport(options);
          await t.start();
          transport = t;
        case 'serial':
          final t = SerialClientTransport(options);
          await t.start();
          transport = t;
        default:
          throw StateError(
            'unsupported extension transport: ${hint['transport']}',
          );
      }
      final conn =
          await connectExtension(clientHost, id: id, transport: transport);
      return conn.id;
    }
    throw StateError('unknown connectHint tool: $tool');
  }

  Future<Map<String, dynamic>> _discoverTool(Map<String, dynamic> args) {
    final timeoutSec = (args['timeoutSeconds'] as num?)?.toDouble();
    return discover(
      (args['source'] as String?) ?? '',
      timeout: timeoutSec == null
          ? kDiscoverScanTimeout
          : Duration(milliseconds: (timeoutSec * 1000).round()),
    );
  }

  Future<Map<String, dynamic>> _connectBleTool(
    Map<String, dynamic> args,
  ) async {
    final deviceId = args['deviceId'] as String?;
    if (deviceId == null || deviceId.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'error': "required field 'deviceId'",
      };
    }
    final id = (args['id'] as String?) ?? 'ble:$deviceId';
    final link =
        _bleLinkFor?.call(deviceId) ?? UniversalBleLink(deviceId: deviceId);
    final transport = BleClientTransport(link: link);
    try {
      await transport.start();
      final conn = await connectExtension(
        clientHost,
        id: id,
        transport: transport,
      );
      return <String, dynamic>{
        'ok': true,
        'id': conn.id,
        'connected': conn.isConnected,
      };
    } catch (_) {
      transport.close();
      rethrow;
    }
  }
}
