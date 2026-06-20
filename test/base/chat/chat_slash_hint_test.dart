/// Unit tests for `ChatSlashHint` value class.
///
/// Boot-independent: pure data + serialization.
///
/// Scenarios:
///   sh1  isDirectDispatch is false when tool is null
///   sh2  isDirectDispatch is false when tool is empty string
///   sh3  isDirectDispatch is true when tool is non-empty
///   sh4  toJson omits optional null fields
///   sh5  toJson includes all fields when provided
///   sh6  fromJson round-trip preserves all fields
///   sh7  fromJson with minimal (command only) JSON
///   sh8  fromJson arguments field: Map is converted, null stays null
///   sh9  template command chip — no tool, has template
///   sh10 direct-dispatch chip — has tool, no template
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/chat/chat_slash_hint.dart';

void main() {
  group('ChatSlashHint.isDirectDispatch', () {
    // sh1
    test('sh1 isDirectDispatch false when tool is null', () {
      const h = ChatSlashHint('/help', 'Summarize ', 'Gets help');
      expect(h.isDirectDispatch, isFalse);
    });

    // sh2
    test('sh2 isDirectDispatch false when tool is empty string', () {
      const h = ChatSlashHint('/cmd', null, null, '');
      expect(h.isDirectDispatch, isFalse);
    });

    // sh3
    test('sh3 isDirectDispatch true when tool is non-empty', () {
      const h = ChatSlashHint('/run', null, null, 'studio.run');
      expect(h.isDirectDispatch, isTrue);
    });
  });

  group('ChatSlashHint.toJson', () {
    // sh4
    test('sh4 toJson omits null optional fields', () {
      const h = ChatSlashHint('/help');
      final j = h.toJson();
      expect(j['command'], '/help');
      expect(j.containsKey('template'), isFalse);
      expect(j.containsKey('description'), isFalse);
      expect(j.containsKey('tool'), isFalse);
      expect(j.containsKey('arguments'), isFalse);
    });

    // sh5
    test('sh5 toJson includes all fields when provided', () {
      const h = ChatSlashHint(
        '/run',
        'run_template ',
        'Run something',
        'studio.run',
        <String, dynamic>{'arg1': 'val1'},
      );
      final j = h.toJson();
      expect(j['command'], '/run');
      expect(j['template'], 'run_template ');
      expect(j['description'], 'Run something');
      expect(j['tool'], 'studio.run');
      expect((j['arguments'] as Map)['arg1'], 'val1');
    });
  });

  group('ChatSlashHint.fromJson', () {
    // sh6
    test('sh6 fromJson round-trip preserves all fields', () {
      const original = ChatSlashHint(
        '/clear',
        null,
        'Clear chat history',
        'chat.clear',
        <String, dynamic>{'confirm': true},
      );
      final json = original.toJson();
      final restored = ChatSlashHint.fromJson(json);
      expect(restored.command, '/clear');
      expect(restored.template, isNull);
      expect(restored.description, 'Clear chat history');
      expect(restored.tool, 'chat.clear');
      expect(restored.arguments!['confirm'], isTrue);
    });

    // sh7
    test('sh7 fromJson with minimal JSON (command only)', () {
      final h = ChatSlashHint.fromJson({'command': '/ping'});
      expect(h.command, '/ping');
      expect(h.template, isNull);
      expect(h.description, isNull);
      expect(h.tool, isNull);
      expect(h.arguments, isNull);
      expect(h.isDirectDispatch, isFalse);
    });

    // sh8
    test('sh8 fromJson arguments: Map is converted, non-Map becomes null', () {
      final withArgs = ChatSlashHint.fromJson({
        'command': '/go',
        'arguments': {'target': 'home'},
      });
      expect(withArgs.arguments!['target'], 'home');

      final withNull = ChatSlashHint.fromJson({
        'command': '/go',
        'arguments': null,
      });
      expect(withNull.arguments, isNull);

      final withString = ChatSlashHint.fromJson({
        'command': '/go',
        'arguments': 'not-a-map',
      });
      expect(withString.arguments, isNull);
    });
  });

  group('ChatSlashHint semantics', () {
    // sh9
    test(
      'sh9 template chip — no tool, has template, isDirectDispatch false',
      () {
        const h = ChatSlashHint(
          '/summarize',
          'Summarize this: ',
          'Summarize the current page',
        );
        expect(h.isDirectDispatch, isFalse);
        expect(h.template, isNotEmpty);
        expect(h.tool, isNull);
      },
    );

    // sh10
    test('sh10 direct-dispatch chip — has tool, isDirectDispatch true', () {
      const h = ChatSlashHint(
        '/export',
        null,
        'Export the project',
        'studio.export',
        <String, dynamic>{'format': 'zip'},
      );
      expect(h.isDirectDispatch, isTrue);
      expect(h.tool, 'studio.export');
      expect(h.arguments!['format'], 'zip');
    });
  });
}
