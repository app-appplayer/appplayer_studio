// VENDORED COPY of the recipe's test — do not hand-edit. Canonical:
//   os/core/brain_kernel/recipes/ble_provisioning/test/provisioning_ui_test.dart
// Re-vendor alongside debug/tool/sync_provisioning_forks.sh runs.
//
import 'package:appplayer_studio/src/base/bridge/ble_provisioning/ble_provisioning.dart';
import 'package:flutter_test/flutter_test.dart';

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
  final doc = buildProvisioningUi();

  test('drives the provision.* tool surface (candidates + commission)', () {
    final tools = {
      for (final b in _nodes(doc, 'button'))
        if (b['onTap'] is Map && (b['onTap'] as Map)['type'] == 'tool')
          (b['onTap'] as Map)['tool']: (b['onTap'] as Map)['params'],
    };
    expect(tools.keys, containsAll(['provision.candidates', 'provision.commission']));
    final commission = tools['provision.commission'] as Map;
    expect(commission['deviceId'], '{{deviceId}}');
    expect(commission['ssid'], '{{ssid}}');
    expect(commission['password'], '{{password}}');
  });

  test('has SSID + password inputs and a candidates list bound to state', () {
    final binds =
        _nodes(doc, 'textInput').map((t) => t['value']).toSet();
    expect(binds, containsAll(['{{ssid}}', '{{password}}']));

    final lists = _nodes(doc, 'list');
    expect(lists, hasLength(1));
    expect(lists.single['items'], '{{candidates}}');
  });
}
