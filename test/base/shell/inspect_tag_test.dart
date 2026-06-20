/// Unit tests for `inspectTag` — the MetaData wrap helper used across
/// chrome surfaces so `studio.renderer.layout_snapshot` can surface
/// stable `{type, id, label}` entries for each click target without
/// the LLM having to compute logical-pixel coordinates.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/shell/inspect_tag.dart';

void main() {
  testWidgets('inspectTag wraps child in MetaData with type only', (
    tester,
  ) async {
    final child = Container(key: const Key('inner'));
    final w = inspectTag(type: 'launcher_tile', child: child);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: w)));
    final meta = tester.widget<MetaData>(find.byType(MetaData));
    expect(meta.metaData, isA<Map>());
    expect((meta.metaData as Map)['type'], 'launcher_tile');
    expect((meta.metaData as Map).containsKey('id'), isFalse);
    expect(meta.behavior, HitTestBehavior.translucent);
    expect(find.byKey(const Key('inner')), findsOneWidget);
  });

  testWidgets('inspectTag omits empty id / label / text / title', (
    tester,
  ) async {
    final w = inspectTag(
      type: 'sub_tab',
      id: '',
      label: '',
      text: '',
      title: '',
      child: const SizedBox.shrink(),
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: w)));
    final meta = tester.widget<MetaData>(find.byType(MetaData)).metaData as Map;
    expect(meta.keys.toSet(), <String>{'type'});
  });

  testWidgets('inspectTag emits id / label / text / title when supplied', (
    tester,
  ) async {
    final w = inspectTag(
      type: 'dialog_action',
      id: 'save',
      label: 'Save',
      text: 'Save button',
      title: 'Save dialog action',
      child: const SizedBox.shrink(),
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: w)));
    final meta = tester.widget<MetaData>(find.byType(MetaData)).metaData as Map;
    expect(meta['type'], 'dialog_action');
    expect(meta['id'], 'save');
    expect(meta['label'], 'Save');
    expect(meta['text'], 'Save button');
    expect(meta['title'], 'Save dialog action');
  });

  testWidgets('inspectTag merges extras without overriding canonical keys', (
    tester,
  ) async {
    final w = inspectTag(
      type: 'instance_card',
      id: 'card_1',
      extra: <String, dynamic>{
        'index': 1,
        // Should NOT override `id` (canonical key precedence).
        'id': 'should_be_ignored',
        // Should NOT override `type` either.
        'type': 'should_be_ignored',
      },
      child: const SizedBox.shrink(),
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: w)));
    final meta = tester.widget<MetaData>(find.byType(MetaData)).metaData as Map;
    expect(meta['type'], 'instance_card');
    expect(meta['id'], 'card_1');
    expect(meta['index'], 1);
  });

  testWidgets('inspectTag preserves the child widget identity', (tester) async {
    final keyHolder = const Key('hold');
    final w = inspectTag(
      type: 'sub_tab',
      id: 'home',
      child: Container(key: keyHolder),
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: w)));
    expect(find.byKey(keyHolder), findsOneWidget);
  });
}
