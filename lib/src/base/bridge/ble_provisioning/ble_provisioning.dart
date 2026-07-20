// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_provisioning/lib/ble_provisioning.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// ble_provisioning — BLE device provisioning (network commissioning) capability.
///
/// The "bring a device near the phone → it joins the local network" onboarding.
/// A sibling of `ble_scan` (observe) / `ble_transport` (pipe) / `device_discovery`
/// (find): provisioning COMPOSES discovery (find a device advertising the
/// provisioning service) + a GATT credential exchange + a join wait, exposed as
/// ONE directly-usable capability ([BleProvisioningCapability]) —
/// `candidates → wifiScan → commission`.
///
/// The radio/GATT is isolated behind [ProvisioningTransport] / [ProvisioningLink]
/// so the orchestration is pure Dart and testable without hardware; the concrete
/// implementation ([UniversalBleProvisioningTransport]) talks real GATT over
/// universal_ble. Vendored by Flutter hosts; publish_to: none.
library;

export 'src/provisioning_models.dart'
    show ProvisioningCandidate, WifiAp, ProvisioningState, ProvisioningStatus;
export 'src/provisioning_link.dart'
    show ProvisioningUuids, ProvisioningLink, ProvisioningTransport;
export 'src/universal_ble_provisioning.dart'
    show UniversalBleProvisioningTransport, UniversalBleProvisioningLink;
export 'src/provisioning_capability.dart' show BleProvisioningCapability;
export 'src/provisioning_ui.dart' show buildProvisioningUi;
