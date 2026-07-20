// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/smartconfig_provisioning/lib/smartconfig_provisioning.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// smartconfig_provisioning — SmartConfig (ESP-Touch v1) Wi-Fi provisioning
/// (network commissioning).
///
/// The "device only listens" onboarding: an unprovisioned ESP32 sniffs Wi-Fi
/// traffic in promiscuous mode while the host — already on the home network —
/// encodes the SSID + password into the LENGTHS of UDP broadcast datagrams
/// (guide code 515/514/513/512, then CRC8/index/data length-coded datum
/// codes). The device decodes the credentials, joins the network, and
/// unicasts an 11-byte ACK (length byte + MAC + IP) to UDP port 18266. A
/// sibling of `ble_provisioning` / `softap_provisioning` — same
/// onboarding→serve goal, different medium.
///
/// The UDP sockets are isolated behind [SmartConfigTransport] so the protocol
/// engine ([SmartConfigSender] + the codec) is pure Dart and testable without
/// a network; the concrete implementation ([UdpSmartConfigTransport]) talks
/// real dart:io UDP. Vendored by Flutter hosts; publish_to: none.
library;

export 'src/smartconfig_codec.dart'
    show
        guideCodeLengths,
        crc8,
        dataCodeLengths,
        buildDatumLengths,
        parseBssid,
        payloadOfLength,
        expectedAckLength;
export 'src/smartconfig_models.dart' show SmartConfigResult;
export 'src/smartconfig_sender.dart'
    show SmartConfigSender, SmartConfigTransport;
export 'src/udp_smartconfig_transport.dart' show UdpSmartConfigTransport;
export 'src/smartconfig_ui.dart' show buildSmartConfigUi;
