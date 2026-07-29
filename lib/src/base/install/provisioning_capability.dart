/// Host wiring for the vendored provisioning recipe set:
/// exposes `provision.*` as host capability tools so a bundle or an agent
/// drives device network onboarding — hand a nearby device the Wi-Fi
/// credentials, await the terminal join — through one JSON surface, over any
/// of the four host-side methods the node firmware supports:
///
///  - `provision.candidates` / `provision.commission` — BLE (GATT): on-demand
///    fresh scan for `mcp-prov` advertisements + creds write with the join
///    awaited over the status NOTIFY. Link-drop tolerant (see below).
///  - `provision.softap_commission` — portal HTTP against a device in SoftAP
///    mode; the host must already be joined to the device's AP.
///  - `provision.serial_ports` / `provision.console` — the node's UART console
///    (`#PROV ` line contract: prov.scan / prov.set / prov.forget /
///    prov.status) over a local serial port. Fully automatable — the
///    regression path of choice.
///  - `provision.smartconfig` — pure-Dart ESP-Touch v1 broadcast sender; the
///    host must sit on the 2.4 GHz band the device is sniffing.
///
/// BLE link-drop recovery (field defect, verified on real hardware): Wi-Fi/BT
/// coexistence on the device can drop the BLE link WHILE it joins Wi-Fi —
/// before the terminal NOTIFY arrives. A drop is not an answer, so the outcome
/// is re-probed over GATT via `readStatus()` polling until terminal
/// (`connecting` is not an answer); two consecutive unreachable probes mean
/// the device rebooted into serving mode = `connected`. Closing the (possibly
/// dead) link is best-effort so a close throw never masks the result we hold.
///
/// The `provision.*` tools live on the shared host registry, so a provisioning
/// bundle's `type:tool` calls reach them in-process (parity rule) exactly like
/// `form.*` / canvas / analysis capabilities.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:brain_kernel/brain_kernel.dart' show HostToolRegistry;

import '../bridge/ble_provisioning/ble_provisioning.dart';
import '../bridge/ble_scan/ble_scan.dart' show UniversalBleScanRadio;
import '../bridge/serial_provisioning/serial_provisioning.dart' as serial;
import '../bridge/smartconfig_provisioning/smartconfig_provisioning.dart'
    as sc;
import '../bridge/softap_provisioning/softap_provisioning.dart' as softap;
import 'capability_recipes/capability_recipes.dart'
    show CapabilityTool, registerCapabilityTools;

/// Capability id — tools register as `provision.<verb>`.
const String provisioningCapabilityId = 'provision';

/// BLE device name a node advertises in provisioning mode (firmware
/// `ble_svc_gap_device_name_set("mcp-prov")`). Part of the provisioning
/// contract; used as the macOS-reliable candidate match (see
/// [provisioningCandidates]).
const String _provisioningAdvertisedName = 'mcp-prov';

/// Register the `provision.*` tool surface on [registry].
List<String> registerProvisioningCapability(HostToolRegistry registry) {
  return registerCapabilityTools(
    registry,
    capabilityId: provisioningCapabilityId,
    tools: <CapabilityTool>[
      CapabilityTool(
        verb: 'candidates',
        description: 'Scan for BLE devices currently in provisioning mode '
            '(advertising the provisioning service). On-demand fresh 3s scan — '
            'call it (Refresh) after Bluetooth is ready; a boot-time scan is '
            'empty because CoreBluetooth is not yet up.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        invoke: (args) => provisioningCandidates(),
      ),
      CapabilityTool(
        verb: 'commission',
        description: 'Send Wi-Fi credentials to a provisioning-mode BLE device '
            '(deviceId from provision.candidates) and await the terminal join '
            'result — `connected` with the obtained ip, or `failed`. Tolerates '
            'the BLE link dropping mid-join (Wi-Fi/BT coex): re-probes the '
            'status over GATT READ until terminal.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'deviceId': <String, dynamic>{'type': 'string'},
            'ssid': <String, dynamic>{'type': 'string'},
            'password': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['deviceId', 'ssid', 'password'],
        },
        invoke: (args) => commissionViaNotify(
          deviceId: args['deviceId'] as String,
          ssid: args['ssid'] as String,
          password: (args['password'] as String?) ?? '',
        ),
      ),
      CapabilityTool(
        verb: 'softap_commission',
        description: 'Commission a device in SoftAP provisioning mode over its '
            'portal HTTP API. The host must ALREADY be joined to the device\'s '
            'AP (e.g. mcp-prov-XXXX) so the portal (default http://192.168.4.1) '
            'is reachable — joining the AP is the operator\'s step on desktop. '
            'POSTs the credentials, then polls /status to the terminal state.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'ssid': <String, dynamic>{'type': 'string'},
            'password': <String, dynamic>{'type': 'string'},
            'portalBase': <String, dynamic>{
              'type': 'string',
              'description': 'Portal base URL (default http://192.168.4.1)',
            },
          },
          'required': <String>['ssid', 'password'],
        },
        invoke: (args) => softApCommission(
          ssid: args['ssid'] as String,
          password: (args['password'] as String?) ?? '',
          portalBase:
              (args['portalBase'] as String?) ?? 'http://192.168.4.1',
        ),
      ),
      CapabilityTool(
        verb: 'serial_ports',
        description: 'List local serial port device paths a node console could '
            'be attached to (macOS/Linux: /dev/cu.* and /dev/ttyUSB* / '
            '/dev/ttyACM*).',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        invoke: (args) => listSerialPorts(),
      ),
      CapabilityTool(
        verb: 'console',
        description: 'Drive a node\'s provisioning console over a local serial '
            'port (`#PROV ` line contract). op: scan (APs the device sees) | '
            'commission (send creds, await terminal join) | forget (clear '
            'stored creds; device re-enters provisioning mode on reset) | '
            'status (provisioned/ssid/ip). NOTE opening the port RESETS the '
            'board (DTR/RTS) — the tool waits bootDelaySeconds (default 9) '
            'before sending so commands don\'t land before Wi-Fi init.',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'port': <String, dynamic>{
              'type': 'string',
              'description': 'Serial device path, e.g. /dev/cu.usbserial-1120',
            },
            'op': <String, dynamic>{
              'type': 'string',
              'enum': <String>['scan', 'commission', 'forget', 'status'],
            },
            'ssid': <String, dynamic>{'type': 'string'},
            'password': <String, dynamic>{'type': 'string'},
            'baud': <String, dynamic>{'type': 'integer'},
            'bootDelaySeconds': <String, dynamic>{'type': 'integer'},
          },
          'required': <String>['port', 'op'],
        },
        invoke: (args) => provisioningConsole(
          port: args['port'] as String,
          op: args['op'] as String,
          ssid: args['ssid'] as String?,
          password: args['password'] as String?,
          baud: (args['baud'] as num?)?.toInt() ?? 115200,
          bootDelaySeconds: (args['bootDelaySeconds'] as num?)?.toInt() ?? 9,
        ),
      ),
      CapabilityTool(
        verb: 'smartconfig',
        description: 'Broadcast Wi-Fi credentials to a device in SmartConfig '
            '(ESP-Touch v1) listening mode and await its ACK (mac + ip). The '
            'host must be ON THE 2.4 GHz BAND of the target network — a device '
            'cannot sniff a 5 GHz sender. bssid narrows the AP match '
            '(\'\' = SSID alone).',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'ssid': <String, dynamic>{'type': 'string'},
            'password': <String, dynamic>{'type': 'string'},
            'bssid': <String, dynamic>{'type': 'string'},
            'timeoutSeconds': <String, dynamic>{'type': 'integer'},
          },
          'required': <String>['ssid', 'password'],
        },
        invoke: (args) => smartConfigProvision(
          ssid: args['ssid'] as String,
          password: (args['password'] as String?) ?? '',
          bssid: (args['bssid'] as String?) ?? '',
          timeout: Duration(
              seconds: (args['timeoutSeconds'] as num?)?.toInt() ?? 45),
        ),
      ),
    ],
  );
}

// ── BLE ────────────────────────────────────────────────────────────

/// On-demand fresh scan for devices in provisioning mode.
///
/// A device is a candidate if it advertises the provisioning service UUID OR
/// its name marks it as a provisioning device (`mcp-prov`). Name matching is
/// the load-bearing path on macOS: the firmware puts the 128-bit service UUID
/// in the primary ADV packet and the name in the scan response, and Core
/// Bluetooth / universal_ble do not reliably surface a 128-bit service UUID
/// from a scan advertisement — the name comes through the active-scan
/// response. Android surfaces both, so the UUID path covers it there.
Future<Map<String, Object?>> provisioningCandidates() async {
  final radio = UniversalBleScanRadio();
  final seen = <String, Map<String, Object?>>{};
  final sub = radio.advertisements
      .where((ad) =>
          ad.serviceUuids.contains(ProvisioningUuids.serviceUuid) ||
          ad.name.toLowerCase().startsWith(_provisioningAdvertisedName))
      .listen((ad) => seen[ad.deviceId] = <String, Object?>{
            'deviceId': ad.deviceId,
            'name': ad.name.isEmpty ? ad.deviceId : ad.name,
            'rssi': ad.rssi,
          });
  await radio.start();
  await Future<void>.delayed(const Duration(seconds: 3));
  await sub.cancel();
  await radio.stop();
  return <String, Object?>{'candidates': seen.values.toList()};
}

/// Commission a provisioning-mode device: connect, write the credentials, and
/// await the device's terminal status over the status NOTIFY. If the BLE link
/// drops after the credentials went out (device-side Wi-Fi/BT coex during the
/// join), the outcome is re-probed over GATT READ instead of failing.
Future<Map<String, Object?>> commissionViaNotify({
  required String deviceId,
  required String ssid,
  required String password,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final link = await UniversalBleProvisioningTransport().open(deviceId);
  var credentialsSent = false;
  try {
    // Subscribe to the terminal status BEFORE writing credentials so the
    // connecting/connected notifications are not missed.
    final terminal = link.status.firstWhere((s) => s.isTerminal).timeout(
          timeout,
          onTimeout: () => const ProvisioningStatus(
              state: ProvisioningState.failed, error: 'timeout'),
        );
    await link.sendCredentials(ssid, password);
    credentialsSent = true;
    final result = await terminal;
    return <String, Object?>{'deviceId': deviceId, ...result.toJson()};
  } on Object {
    if (!credentialsSent) rethrow;
    return _reprobeAfterLinkDrop(deviceId);
  } finally {
    // Best-effort: on success the device reboots into serving mode and drops
    // BLE first, so closing the already-dead link can throw — that must not
    // mask the terminal status we already have.
    try {
      await link.close();
    } on Object catch (_) {}
  }
}

Future<Map<String, Object?>> _reprobeAfterLinkDrop(String deviceId) async {
  // Poll until the join reaches a TERMINAL outcome. Right after the drop the
  // device is usually still joining (status reads `connecting` — not an
  // answer). Keep reading until connected/failed, and treat the device
  // vanishing from BLE (two consecutive unreachable probes) as the success
  // reboot into serving mode.
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  var unreachable = 0;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(seconds: 3));
    ProvisioningLink? link;
    try {
      link = await UniversalBleProvisioningTransport()
          .open(deviceId)
          .timeout(const Duration(seconds: 6));
      final st = await link.readStatus().timeout(const Duration(seconds: 4));
      if (st.isTerminal) {
        return <String, Object?>{'deviceId': deviceId, ...st.toJson()};
      }
      unreachable = 0; // still provisioning — keep polling
    } on Object {
      unreachable++;
      if (unreachable >= 2) {
        return <String, Object?>{
          'deviceId': deviceId,
          'state': 'connected',
          'ip': '',
        };
      }
    } finally {
      try {
        await link?.close();
      } on Object catch (_) {}
    }
  }
  return <String, Object?>{
    'deviceId': deviceId,
    'state': 'failed',
    'error': 'reprobe-timeout',
  };
}

// ── SoftAP ─────────────────────────────────────────────────────────

/// Portal-HTTP commission against a device whose AP the host already joined.
Future<Map<String, Object?>> softApCommission({
  required String ssid,
  required String password,
  required String portalBase,
}) async {
  final client = softap.SoftApProvisioningClient(baseUrl: portalBase);
  try {
    return await client.commission(ssid, password);
  } finally {
    client.close();
  }
}

// ── Serial console ─────────────────────────────────────────────────

/// Serial device paths that plausibly carry a node console.
Future<Map<String, Object?>> listSerialPorts() async {
  final ports = <String>[];
  final dev = Directory('/dev');
  if (await dev.exists()) {
    await for (final e in dev.list(followLinks: false)) {
      final name = e.path.split('/').last;
      if (name.startsWith('cu.') ||
          name.startsWith('ttyUSB') ||
          name.startsWith('ttyACM')) {
        ports.add(e.path);
      }
    }
  }
  ports.sort();
  return <String, Object?>{'ports': ports};
}

/// One console operation over a real serial port.
///
/// The whole serial exchange runs in a BACKGROUND ISOLATE ([Isolate.run]): a
/// tty is not seekable, so it must be driven with blocking `readSync` polling,
/// and doing that on the main isolate freezes the Flutter app and the MCP
/// server (every other tool call stalls). The isolate polls a raw port
/// (`stty raw -echo <baud> min 0 time 1`) and speaks the `#PROV ` line
/// protocol; only the plain-map result crosses back.
///
/// Opening the port pulses DTR/RTS and resets the board (unavoidable on
/// macOS), so the command is sent only after [bootDelaySeconds].
Future<Map<String, Object?>> provisioningConsole({
  required String port,
  required String op,
  String? ssid,
  String? password,
  int baud = 115200,
  int bootDelaySeconds = 9,
}) async {
  if (op == 'commission' && (ssid == null || ssid.isEmpty)) {
    return const <String, Object?>{
      'ok': false,
      'error': 'commission requires ssid (and usually password)',
    };
  }
  final args = <String, Object?>{
    'port': port,
    'op': op,
    'ssid': ssid,
    'password': password,
    'baud': baud,
    'bootDelay': bootDelaySeconds,
  };
  return Isolate.run(() => _consoleWorker(args));
}

/// Runs inside a background isolate — blocking serial I/O only. Returns a
/// sendable plain map.
Future<Map<String, Object?>> _consoleWorker(Map<String, Object?> args) async {
  final port = args['port'] as String;
  final op = args['op'] as String;
  final ssid = args['ssid'] as String?;
  final password = args['password'] as String?;
  final baud = args['baud'] as int;
  final bootDelay = args['bootDelay'] as int;

  final file = File(port);
  RandomAccessFile? reader;
  RandomAccessFile? writer;
  serial.SerialProvisioningClient? client;
  final fromDevice = StreamController<List<int>>();
  var polling = true;
  try {
    reader = file.openSync(mode: FileMode.read);
    // NOT writeOnlyAppend: append seeks to end, and a tty is non-seekable
    // (open fails with "Illegal seek", errno 29). writeOnly's O_TRUNC is a
    // no-op on a character device.
    writer = file.openSync(mode: FileMode.writeOnly);
    // Configure termios AFTER opening, so the settings apply to the fds we
    // hold open. Running `stty -f` before opening is unreliable on macOS: the
    // tty resets to defaults (9600 baud, canonical mode) on the LAST close, so
    // a subsequent fresh open would lose raw/115200 and garble the exchange.
    // `min 0 time 1`: readSync returns after ≤0.1s with whatever bytes are
    // available (0 allowed), so the poll loop never blocks on an idle port.
    final stty = await Process.run(
      'stty',
      <String>['-f', port, 'raw', '-echo', '$baud', 'min', '0', 'time', '1'],
    );
    if (stty.exitCode != 0) {
      return <String, Object?>{
        'ok': false,
        'error': 'stty failed: ${stty.stderr.toString().trim()}',
      };
    }
    final r = reader;
    Future<void> pump() async {
      while (polling) {
        final chunk = r.readSync(512);
        if (chunk.isNotEmpty) {
          fromDevice.add(chunk);
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
    }

    unawaited(pump());
    client = serial.SerialProvisioningClient(
      fromDevice: fromDevice.stream,
      toDevice: (bytes) => writer!.writeFromSync(bytes),
    );
    await Future<void>.delayed(Duration(seconds: bootDelay));
    switch (op) {
      case 'scan':
        final aps = await client.scan();
        return <String, Object?>{
          'aps': <Object?>[for (final a in aps) a.toJson()],
        };
      case 'commission':
        return await client.commission(ssid!, password ?? '');
      case 'forget':
        await client.forget();
        return const <String, Object?>{'ok': true};
      case 'status':
        return (await client.status()).toJson();
      default:
        return <String, Object?>{'ok': false, 'error': 'unknown op: $op'};
    }
  } on TimeoutException {
    return const <String, Object?>{'ok': false, 'error': 'timeout'};
  } finally {
    polling = false;
    await client?.dispose();
    await fromDevice.close();
    reader?.closeSync();
    writer?.closeSync();
  }
}

// ── SmartConfig ────────────────────────────────────────────────────

/// ESP-Touch v1 broadcast until the device ACKs (mac + ip) or timeout.
Future<Map<String, Object?>> smartConfigProvision({
  required String ssid,
  required String password,
  String bssid = '',
  Duration timeout = const Duration(seconds: 45),
}) async {
  final transport = await sc.UdpSmartConfigTransport.bind();
  try {
    final result = await sc.SmartConfigSender(transport: transport).provision(
      ssid: ssid,
      password: password,
      bssid: bssid,
      timeout: timeout,
    );
    return <String, Object?>{
      'state': 'connected',
      'mac': result.mac,
      'ip': result.ip,
    };
  } on TimeoutException {
    return const <String, Object?>{'state': 'failed', 'error': 'timeout'};
  } finally {
    await transport.close();
  }
}
