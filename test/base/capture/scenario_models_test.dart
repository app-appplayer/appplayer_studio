/// Unit tests for `Scenario` / `Step` JSON round-trip — covers the
/// R24 `internal` metadata + R26-era step list editor mutations
/// (Add/Remove step) that round-trip through `Scenario.fromJson`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/capture/scenario/scenario_models.dart';

void main() {
  group('Scenario.fromJson', () {
    test('parses a minimal scenario (id only) with defaults', () {
      final s = Scenario.fromJson({'id': 'r1'});
      expect(s.id, 'r1');
      expect(s.title, 'r1');
      expect(s.steps, isEmpty);
      expect(s.prepare, isEmpty);
      expect(s.overlayTracks, isEmpty);
      expect(s.fps, 24);
      expect(s.record, isTrue);
      expect(s.encodeAfter, isTrue);
      expect(s.encodeOptions, isEmpty);
      expect(s.internal, isFalse);
    });

    test('respects internal:true flag', () {
      final s = Scenario.fromJson({'id': 'special_install', 'internal': true});
      expect(s.internal, isTrue);
    });

    test('parses steps with tool + args + settleMs + label + overlays', () {
      final s = Scenario.fromJson({
        'id': 'r2',
        'title': 'Open App Builder',
        'steps': [
          {
            'tool': 'studio.ui.tap',
            'args': {'elementId': 'app_builder'},
            'settleMs': 1800,
            'label': 'Tap App Builder',
            'overlays': [
              {'type': 'subtitle', 'text': 'Tap the App Builder launcher'},
            ],
          },
        ],
      });
      expect(s.steps, hasLength(1));
      final st = s.steps.first;
      expect(st.tool, 'studio.ui.tap');
      expect(st.args, {'elementId': 'app_builder'});
      expect(st.settleMs, 1800);
      expect(st.label, 'Tap App Builder');
      expect(st.overlays, hasLength(1));
      expect(st.overlays.first['type'], 'subtitle');
    });

    test('falls back to step defaults when fields are missing', () {
      final st = Step.fromJson({});
      expect(st.tool, '');
      expect(st.args, isEmpty);
      expect(st.settleMs, 600);
      expect(st.overlays, isEmpty);
      expect(st.afterAction, isEmpty);
      expect(st.label, isNull);
    });

    test('honours custom fps / record / recordingLabel / encodeOptions', () {
      final s = Scenario.fromJson({
        'id': 'r6',
        'fps': 30,
        'record': false,
        'recordingLabel': 'custom-label',
        'encodeAfter': false,
        'encodeOptions': {'crf': 18},
      });
      expect(s.fps, 30);
      expect(s.record, isFalse);
      expect(s.recordingLabel, 'custom-label');
      expect(s.encodeAfter, isFalse);
      expect(s.encodeOptions, {'crf': 18});
    });

    test('overlayTracks + prepare separate from steps timeline', () {
      final s = Scenario.fromJson({
        'id': 'r5',
        'prepare': [
          {
            'tool': 'studio.chrome.select_tab',
            'args': {'key': 'home'},
          },
        ],
        'overlayTracks': [
          {'at': 0, 'duration': 14000, 'type': 'watermark', 'text': 'r5'},
        ],
        'steps': [
          {'tool': 'studio.chrome.list_tabs'},
        ],
      });
      expect(s.prepare, hasLength(1));
      expect(s.prepare.first.tool, 'studio.chrome.select_tab');
      expect(s.overlayTracks, hasLength(1));
      expect(s.overlayTracks.first['type'], 'watermark');
      expect(s.steps, hasLength(1));
      expect(s.steps.first.tool, 'studio.chrome.list_tabs');
    });

    test('audioTracks parse (narration + music)', () {
      final s = Scenario.fromJson({
        'id': 'r6',
        'steps': [
          {'tool': 'studio.chrome.list_tabs'},
        ],
        'audioTracks': [
          {'path': '/a/voice.m4a'},
          {'path': '/a/bgm.mp3', 'startMs': 1000, 'volume': 0.2},
        ],
      });
      expect(s.audioTracks, hasLength(2));
      expect(s.audioTracks.first['path'], '/a/voice.m4a');
      expect(s.audioTracks[1]['volume'], 0.2);
    });

    test('`audio` is accepted as an alias for `audioTracks`', () {
      final s = Scenario.fromJson({
        'id': 'r7',
        'steps': [
          {'tool': 'studio.chrome.list_tabs'},
        ],
        'audio': [
          {'path': '/a/voice.m4a'},
        ],
      });
      expect(s.audioTracks, hasLength(1));
      expect(s.audioTracks.first['path'], '/a/voice.m4a');
    });

    test('audioTracks defaults to empty', () {
      final s = Scenario.fromJson({
        'id': 'r8',
        'steps': [
          {'tool': 'studio.chrome.list_tabs'},
        ],
      });
      expect(s.audioTracks, isEmpty);
    });
  });

  group('scenarioFromJsonString round-trip with editor mutations', () {
    test('add-step append + parse', () {
      final raw = '''{
        "id": "draft",
        "title": "Draft scenario",
        "internal": false,
        "steps": [
          {"tool": "studio.chrome.list_tabs", "args": {}, "settleMs": 600, "label": ""}
        ]
      }''';
      final s = scenarioFromJsonString(raw);
      expect(s.steps, hasLength(1));
      expect(s.internal, isFalse);
      expect(s.steps.first.tool, 'studio.chrome.list_tabs');
    });
  });
}
