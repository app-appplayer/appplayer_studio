// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_provisioning/lib/src/provisioning_ui.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// A demo bundle (mcp_ui_dsl v1.0) driving the provisioning capability's tool
/// surface: refresh candidates → enter Wi-Fi SSID/password → commission → watch
/// the status. The bundle carries no logic — each button invokes a
/// `provision.*` tool whose plain-map result auto-merges into page state
/// (§3.10), so no explicit result binding is needed.
library;

Map<String, Object?> buildProvisioningUi() {
  Map<String, Object?> toolBtn(
    String label,
    String tool,
    Map<String, Object?> params,
  ) =>
      {
        'type': 'button',
        'label': label,
        'onTap': {'type': 'tool', 'tool': tool, 'params': params},
      };

  Map<String, Object?> field(String label, String bind) => {
        'type': 'textInput',
        'label': label,
        'value': '{{$bind}}',
        'onChange': {
          'type': 'state',
          'action': 'set',
          'binding': bind,
          'value': '{{event.value}}',
        },
      };

  return {
    'type': 'page',
    'title': 'Device Provisioning',
    'initialState': {
      'candidates': <Object?>[],
      'deviceId': '',
      'ssid': '',
      'password': '',
      'state': 'idle',
      'ip': '',
    },
    'content': {
      'type': 'linear',
      'direction': 'vertical',
      'spacing': 12,
      'padding': 16,
      'children': [
        {
          'type': 'text',
          'text': 'Provision a nearby device onto Wi-Fi',
          'variant': 'titleLarge',
        },
        {
          'type': 'text',
          'variant': 'bodyMedium',
          'text': 'Bring the device close (provisioning mode). Refresh to find '
              'it, pick it, enter Wi-Fi, then Commission.',
        },
        toolBtn('Refresh devices', 'provision.candidates', const {}),
        {
          'type': 'list',
          'shrinkWrap': true,
          'items': '{{candidates}}',
          'emptyMessage': 'No devices in provisioning mode — Refresh.',
          'itemTemplate': {
            'type': 'button',
            'label': '{{item.name}}  ·  {{item.rssi}} dBm',
            'onTap': {
              'type': 'state',
              'action': 'set',
              'binding': 'deviceId',
              'value': '{{item.deviceId}}',
            },
          },
        },
        {'type': 'text', 'text': 'Selected: {{deviceId}}', 'variant': 'bodySmall'},
        field('Wi-Fi SSID', 'ssid'),
        field('Password', 'password'),
        {
          'type': 'button',
          'label': 'Commission',
          'onTap': {
            'type': 'tool',
            'tool': 'provision.commission',
            'params': {
              'deviceId': '{{deviceId}}',
              'ssid': '{{ssid}}',
              'password': '{{password}}',
            },
            // The commission round-trip can exceed the runtime's 30s default:
            // join (~10s) plus the link-drop reprobe window (up to 30s).
            'timeout': 60000,
          },
        },
        {
          'type': 'text',
          'variant': 'titleMedium',
          'text': 'Status: {{state}}   {{ip}}',
        },
      ],
    },
  };
}
