// VENDORED COPY of the recipe's test — do not hand-edit. Canonical:
//   os/core/brain_kernel/recipes/smartconfig_provisioning/test/smartconfig_ui_test.dart
// Re-vendor alongside debug/tool/sync_provisioning_forks.sh runs.
//
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/bridge/smartconfig_provisioning/smartconfig_provisioning.dart';

List<Map<String, Object?>> _nodes(Object? node, String type) {
  final out = <Map<String, Object?>>[];
  void visit(Object? n) {
    if (n is Map<String, Object?>) {
      if (n['type'] == type) out.add(n);
      n.values.forEach(visit);
    } else if (n is List) {
      n.forEach(visit);
    }
  }

  visit(node);
  return out;
}

void main() {
  final doc = buildSmartConfigUi();

  test('drives the smartconfig.* tool surface', () {
    final tools = {
      for (final b in _nodes(doc, 'button'))
        if (b['onTap'] is Map && (b['onTap'] as Map)['type'] == 'tool')
          (b['onTap'] as Map)['tool']: (b['onTap'] as Map)['params'],
    };
    expect(tools.keys, contains('smartconfig.provision'));
    final provision = tools['smartconfig.provision'] as Map;
    expect(provision['ssid'], '{{ssid}}');
    expect(provision['password'], '{{password}}');
  });

  test('has SSID + password inputs bound to state', () {
    final binds = _nodes(doc, 'textInput').map((t) => t['value']).toSet();
    expect(binds, containsAll(['{{ssid}}', '{{password}}']));
  });
}
