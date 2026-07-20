// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/serial_provisioning/lib/serial_provisioning.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// serial_provisioning — serial (UART console) Wi-Fi provisioning (network
/// commissioning).
///
/// The "plug in a cable" onboarding: the host sends LF-terminated `prov.*`
/// command lines over the device's console (`prov.scan`,
/// `prov.set "<ssid>" "<password>"`, `prov.forget`, `prov.status`) and the
/// firmware answers
/// with single-line JSON payloads behind a `#PROV ` sentinel, interleaved with
/// ordinary log noise which the client ignores. A sibling of
/// `ble_provisioning` / `softap_provisioning` / `smartconfig_provisioning` —
/// same onboarding→serve goal, aligned JSON payload shapes, different medium
/// (a byte pipe instead of a radio).
///
/// The client ([SerialProvisioningClient]) is transport-agnostic — it takes a
/// `Stream<List<int>>` from the device and a `void Function(List<int>)` to it,
/// no dart:io serial dependency — so it is pure Dart and testable with
/// scripted byte streams; the host wires a real serial port. Vendored by
/// Flutter hosts; publish_to: none.
library;

export 'src/serial_models.dart'
    show WifiAp, ProvisioningState, ProvisioningStatus, ProvisioningInfo;
export 'src/serial_client.dart' show SerialProvisioningClient;
export 'src/serial_ui.dart' show buildSerialProvisioningUi;
