import 'package:appplayer_studio/src/base/bridge/ble_scan/ble_scan.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, Object?>> _nodesOfType(Object? node, String type) {
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
  final doc = buildBleScanMonitorUi();

  test('is a titled page seeded with empty subscription + advertisements', () {
    expect(doc['type'], 'page');
    final state = doc['initialState'] as Map<String, Object?>;
    expect(state['subscriptionId'], '');
    expect(state['advertisements'], isEmpty);
  });

  test('Start/Refresh/Stop drive the ble.scan.* tools (auto-merge, no bind)',
      () {
    final tools = {
      for (final b in _nodesOfType(doc, 'button'))
        b['label']: b['onTap'] as Map<String, Object?>,
    };
    expect(tools.keys, containsAll(['Start', 'Refresh', 'Stop']));
    expect(tools['Start']!['tool'], 'ble.scan.start');
    expect(tools['Refresh']!['tool'], 'ble.scan.poll');
    expect((tools['Refresh']!['params'] as Map)['subscriptionId'],
        '{{subscriptionId}}');
    expect(tools['Stop']!['tool'], 'ble.scan.stop');
    // Rely on §3.10 top-level auto-merge, not an explicit result binding.
    expect(tools.values.every((t) => t['bindResult'] == null), isTrue);
  });

  test('a list binds to the merged advertisements and renders name + rssi', () {
    final lists = _nodesOfType(doc, 'list');
    expect(lists, hasLength(1));
    final list = lists.single;
    expect(list['items'], '{{advertisements}}');
    final template = list['itemTemplate'] as Map<String, Object?>;
    final texts = _nodesOfType(template, 'text').map((t) => t['text']).toList();
    expect(texts, containsAll(['{{item.name}}', '{{item.rssi}} dBm']));
  });
}
