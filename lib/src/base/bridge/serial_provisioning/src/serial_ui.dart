// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/serial_provisioning/lib/src/serial_ui.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// A demo bundle (mcp_ui_dsl v1.0) driving the serial provisioning tool
/// surface. The host has the device's console open (a serial port wired into
/// the client); Scan reads the device's Wi-Fi list, the user enters the home
/// SSID/password, Commission sends them and awaits the join. Each button
/// invokes a `serial_prov.*` tool whose plain-map result auto-merges into page
/// state (§3.10).
library;

Map<String, Object?> buildSerialProvisioningUi() {
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
    'title': 'Serial Provisioning',
    'initialState': {
      'aps': <Object?>[],
      'ssid': '',
      'password': '',
      'state': 'idle',
      'ip': '',
      'provisioned': false,
    },
    'content': {
      'type': 'linear',
      'direction': 'vertical',
      'spacing': 12,
      'padding': 16,
      'children': [
        {
          'type': 'text',
          'text': 'Provision over the device console (UART)',
          'variant': 'titleLarge',
        },
        {
          'type': 'text',
          'variant': 'bodyMedium',
          'text': 'Connect the device console first. Scan reads its Wi-Fi '
              'list; enter your home network, then Commission.',
        },
        toolBtn('Scan Wi-Fi', 'serial_prov.scan', const {}),
        {
          'type': 'list',
          'shrinkWrap': true,
          'items': '{{aps}}',
          'emptyMessage': 'No networks yet — Scan (console must be connected).',
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
        toolBtn('Commission', 'serial_prov.commission', {
          'ssid': '{{ssid}}',
          'password': '{{password}}',
        }),
        {
          'type': 'linear',
          'direction': 'horizontal',
          'spacing': 12,
          'children': [
            toolBtn('Status', 'serial_prov.status', const {}),
            toolBtn('Forget', 'serial_prov.forget', const {}),
          ],
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
