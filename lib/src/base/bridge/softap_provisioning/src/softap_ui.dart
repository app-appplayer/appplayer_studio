// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/softap_provisioning/lib/src/softap_ui.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// A demo bundle (mcp_ui_dsl v1.0) driving the SoftAP provisioning tool surface.
/// The host must already be on the device's AP; then Refresh reads the device's
/// Wi-Fi list, the user enters the home SSID/password, Commission POSTs them and
/// awaits the join. Each button invokes a `softap.*` tool whose plain-map result
/// auto-merges into page state (§3.10).
library;

Map<String, Object?> buildSoftApProvisioningUi() {
  Map<String, Object?> toolBtn(
          String label, String tool, Map<String, Object?> params) =>
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
    'title': 'SoftAP Provisioning',
    'initialState': {
      'aps': <Object?>[],
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
          'text': 'Provision over the device Wi-Fi (SoftAP)',
          'variant': 'titleLarge',
        },
        {
          'type': 'text',
          'variant': 'bodyMedium',
          'text': 'Join the device AP (mcp-prov-XXXX) first. Refresh reads its '
              'Wi-Fi list; enter your home network, then Commission.',
        },
        toolBtn('Refresh Wi-Fi', 'softap.wifiScan', const {}),
        {
          'type': 'list',
          'shrinkWrap': true,
          'items': '{{aps}}',
          'emptyMessage': 'No networks yet — Refresh (must be on the device AP).',
          'itemTemplate': {
            'type': 'button',
            'label': '{{item.ssid}}  ·  {{item.rssi}} dBm',
            'onTap': {
              'type': 'state',
              'action': 'set',
              'binding': 'ssid',
              'value': '{{item.ssid}}',
            },
          },
        },
        field('Wi-Fi SSID', 'ssid'),
        field('Password', 'password'),
        toolBtn('Commission', 'softap.commission', {
          'ssid': '{{ssid}}',
          'password': '{{password}}',
        }),
        {
          'type': 'text',
          'variant': 'titleMedium',
          'text': 'Status: {{state}}   {{ip}}',
        },
      ],
    },
  };
}
