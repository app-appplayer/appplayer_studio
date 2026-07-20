// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_scan/lib/src/ble_scan_ui.dart
// Regenerate with debug/tool/sync_ble_scan_fork.sh.
//
/// A demo bundle document (mcp_ui_dsl v1.0) that DRAWS incoming BLE
/// advertisements — the "the bundle draws the advertisement" proof that the observation
/// capability is renderable, not just agent-callable.
///
/// The bundle drives the `ble.scan.*` tools with no logic of its own; each
/// tool's plain-map response auto-merges its top-level keys into page state
/// (mcp_ui_dsl v1.0 §3.10), so no explicit result binding is needed:
///  - **Start** → `ble.scan.start` (a filter); the response's `subscriptionId`
///    merges into state.
///  - **Refresh** → `ble.scan.poll(subscriptionId)`; the response's
///    `advertisements` merges into state.
///  - a `list` binds to `{{advertisements}}` and renders one row per device
///    (name + rssi) — the live monitor.
///
/// Each bundle instance holds its OWN subscription id, so several bundles can
/// observe with different filters over the one shared radio (the hub multiplex).
/// (A periodic auto-poll / a real chart widget are follow-ons; Refresh keeps the
/// demo deterministic and rendered without a timer.)
library;

Map<String, Object?> buildBleScanMonitorUi() {
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

  return {
    'type': 'page',
    'title': 'BLE Scan Monitor',
    'initialState': {
      'subscriptionId': '',
      'advertisements': <Object?>[],
    },
    'content': {
      'type': 'linear',
      'direction': 'vertical',
      'spacing': 12,
      'padding': 16,
      'children': [
        {'type': 'text', 'text': 'BLE Advertisement Monitor', 'variant': 'titleLarge'},
        {
          'type': 'text',
          'text': 'Observe nearby BLE advertisements over the shared radio. '
              'Start to subscribe, Refresh to read the current window.',
          'variant': 'bodyMedium',
        },
        {
          'type': 'linear',
          'direction': 'horizontal',
          'distribution': 'start',
          'spacing': 8,
          'children': [
            // Empty filter = observe everything; a real bundle passes e.g.
            // {"serviceUuids":["abcd"]} or {"minRssi":-70}.
            toolBtn('Start', 'ble.scan.start', const {}),
            toolBtn('Refresh', 'ble.scan.poll',
                {'subscriptionId': '{{subscriptionId}}'}),
            toolBtn('Stop', 'ble.scan.stop',
                {'subscriptionId': '{{subscriptionId}}'}),
          ],
        },
        {
          'type': 'list',
          'shrinkWrap': true,
          'items': '{{advertisements}}',
          'emptyMessage': 'No advertisements yet — Start, then Refresh.',
          'itemTemplate': {
            'type': 'linear',
            'direction': 'horizontal',
            'distribution': 'spaceBetween',
            'children': [
              {'type': 'text', 'text': '{{item.name}}', 'variant': 'bodyLarge'},
              {
                'type': 'text',
                'text': '{{item.rssi}} dBm',
                'variant': 'bodyMedium',
              },
            ],
          },
        },
      ],
    },
  };
}

/// The LIVE variant — the same monitor, but driven by a `client.mcpStream`
/// channel instead of manual Refresh. The bundle declares one channel bound to
/// the `ble://scan` source (its filter in `params.params`); each advertisement
/// arrives as a server push, the channel's `onMessage` appends it to state, and
/// the `list` re-renders with no polling. Start opens the channel (a hub
/// subscription), Stop closes it (decrements the shared radio's ref-count).
///
/// The pushed payload binds as the `data` context variable — the runtime's
/// uniform channel onData contract, the same one `client.poll` / `client.*`
/// channels deliver through.
Map<String, Object?> buildBleScanLiveMonitorUi() {
  Map<String, Object?> channelBtn(String label, String action) => {
        'type': 'button',
        'label': label,
        'onTap': {
          'type': 'channel',
          'action': action,
          'channel': 'advertisements',
        },
      };

  return {
    'type': 'page',
    'title': 'BLE Scan Monitor (Live)',
    'initialState': {
      'advertisements': <Object?>[],
    },
    'channels': {
      // Empty filter = observe everything; a real bundle passes e.g.
      // {"serviceUuids":["abcd"]} or {"minRssi":-70} in params.params.
      'advertisements': {
        'type': 'client.mcpStream',
        'params': {'uri': 'ble://scan', 'params': <String, Object?>{}},
        'onMessage': {
          'type': 'state',
          'action': 'append',
          'binding': 'advertisements',
          'value': '{{data}}',
        },
      },
    },
    'content': {
      'type': 'linear',
      'direction': 'vertical',
      'spacing': 12,
      'padding': 16,
      'children': [
        {
          'type': 'text',
          'text': 'BLE Advertisement Monitor (Live)',
          'variant': 'titleLarge',
        },
        {
          'type': 'text',
          'text': 'Start to subscribe the shared radio; advertisements stream '
              'in and the list grows live — no Refresh.',
          'variant': 'bodyMedium',
        },
        {
          'type': 'linear',
          'direction': 'horizontal',
          'distribution': 'start',
          'spacing': 8,
          'children': [
            channelBtn('Start', 'channel.start'),
            channelBtn('Stop', 'channel.stop'),
          ],
        },
        {
          'type': 'list',
          'shrinkWrap': true,
          'items': '{{advertisements}}',
          'emptyMessage': 'No advertisements yet — Start to observe.',
          'itemTemplate': {
            'type': 'linear',
            'direction': 'horizontal',
            'distribution': 'spaceBetween',
            'children': [
              {'type': 'text', 'text': '{{item.name}}', 'variant': 'bodyLarge'},
              {
                'type': 'text',
                'text': '{{item.rssi}} dBm',
                'variant': 'bodyMedium',
              },
            ],
          },
        },
      ],
    },
  };
}
