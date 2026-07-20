// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/smartconfig_provisioning/lib/src/smartconfig_ui.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// A demo bundle (mcp_ui_dsl v1.0) driving the SmartConfig provisioning tool
/// surface. The host must already be ON the target Wi-Fi network (SmartConfig
/// broadcasts on the network the credentials describe); the user enters the
/// SSID/password and Provision broadcasts them until the device ACKs with its
/// MAC + IP. Each button invokes a `smartconfig.*` tool whose plain-map result
/// auto-merges into page state (§3.10).
library;

Map<String, Object?> buildSmartConfigUi() {
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
    'title': 'SmartConfig Provisioning',
    'initialState': {
      'ssid': '',
      'password': '',
      'state': 'idle',
      'mac': '',
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
          'text': 'Provision over UDP broadcast (ESP-Touch v1)',
          'variant': 'titleLarge',
        },
        {
          'type': 'text',
          'variant': 'bodyMedium',
          'text': 'Join the target Wi-Fi first, put the device in SmartConfig '
              'listen mode, enter that network\'s credentials, then Provision. '
              'The device ACKs with its MAC and IP when it joins.',
        },
        field('Wi-Fi SSID', 'ssid'),
        field('Password', 'password'),
        toolBtn('Provision', 'smartconfig.provision', {
          'ssid': '{{ssid}}',
          'password': '{{password}}',
        }),
        {
          'type': 'text',
          'variant': 'titleMedium',
          'text': 'Status: {{state}}   {{mac}}   {{ip}}',
        },
      ],
    },
  };
}
