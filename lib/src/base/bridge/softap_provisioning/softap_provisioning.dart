// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/softap_provisioning/lib/softap_provisioning.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// softap_provisioning — SoftAP Wi-Fi provisioning (network commissioning).
///
/// The Samsung/LG-style onboarding method: the unprovisioned device hosts a
/// Wi-Fi AP + HTTP server; the host joins that AP and POSTs the home Wi-Fi
/// credentials; the device joins the home network and serves MCP. A sibling of
/// `ble_provisioning` — same onboarding→serve goal, different medium (Wi-Fi AP +
/// HTTP vs BLE GATT), same JSON payload shapes so decoders are shared.
///
/// The recipe is a pure HTTP client ([SoftApProvisioningClient]); getting the
/// host ONTO the device's AP (Wi-Fi switch) is the host platform's concern.
/// Vendored by Flutter hosts; publish_to: none.
library;

export 'src/softap_models.dart'
    show WifiAp, ProvisioningState, ProvisioningStatus;
export 'src/softap_client.dart' show SoftApProvisioningClient;
export 'src/softap_ui.dart' show buildSoftApProvisioningUi;
