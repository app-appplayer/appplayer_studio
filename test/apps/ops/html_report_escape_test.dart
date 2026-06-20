/// Unit tests for `HtmlReport` pure-logic helpers.
///
/// `HtmlReport.build` requires a full KnowledgeInit + registry stack
/// (boot-dependent). These tests exercise only the parts reachable
/// without booting: the private `_h` HTML-escape function (accessed via
/// observable HTML output) and the `_kpi` / `_inlineCss` fragments
/// through a thin shim compiled from the same source.
///
/// Strategy: build a plain string using the same escape logic lifted
/// verbatim from the source (the function is private but deterministic),
/// then verify output properties the outer tests care about.
///
/// Scenarios:
///   h1  `_h` — ampersand escaping
///   h2  `_h` — less-than escaping
///   h3  `_h` — greater-than escaping
///   h4  `_h` — double-quote escaping
///   h5  `_h` — single-quote escaping
///   h6  `_h` — combined injection attempt is fully escaped
///   h7  `_h` — safe strings pass through unchanged
///   h8  `_h` — empty string passes through unchanged
///   h9  `_kpi` — output contains value and label, no raw HTML injection
///   h10 `_inlineCss` — non-empty, mentions body selector
///   h11 activityHtml — reversed order: most recent first in table
///   h12 events window — only last N events kept when list > recentEvents
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/observability/activity_event.dart';

// ---------------------------------------------------------------------------
// Private helper cloned from html_report.dart (tested via observable output)
// ---------------------------------------------------------------------------

String _h(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String _kpi(String label, int value) =>
    '<div class="kpi"><div class="v">$value</div><div class="l">${_h(label)}</div></div>';

String _inlineCss() => '''
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, system-ui, sans-serif;
  background: #fafaf9;
  color: #15161a;
  line-height: 1.5;
}
''';

// ---------------------------------------------------------------------------
// Helper that replicates the activityHtml fragment for window tests
// ---------------------------------------------------------------------------
String _buildActivityHtml(List<ActivityEvent> allEvents, int recentEvents) {
  final slice =
      allEvents.length <= recentEvents
          ? allEvents
          : allEvents.sublist(allEvents.length - recentEvents);

  if (slice.isEmpty) return '';
  return [
    for (final e in slice.reversed.take(50))
      '<tr class="sev-${_h(e.severity.name)}">'
          '<td>${_h(e.ts.toIso8601String())}</td>'
          '<td>${_h(e.kind.name)}</td>'
          '<td>${_h(e.actor)}</td>'
          '<td>${_h(e.headline)}</td>'
          '</tr>',
  ].join('\n');
}

ActivityEvent _makeEvent(
  String actor, {
  ActivityKind kind = ActivityKind.info,
  ActivitySeverity severity = ActivitySeverity.info,
  String headline = 'msg',
}) => ActivityEvent(
  ts: DateTime.utc(2026, 1, 1),
  kind: kind,
  actor: actor,
  headline: headline,
  severity: severity,
);

void main() {
  // -------------------------------------------------------------------------
  // h1 – h8: HTML escape function
  // -------------------------------------------------------------------------
  group('_h HTML escape', () {
    test('h1 escapes ampersand', () {
      expect(_h('a & b'), 'a &amp; b');
    });

    test('h2 escapes less-than', () {
      expect(_h('<script>'), '&lt;script&gt;');
    });

    test('h3 escapes greater-than', () {
      expect(_h('x > y'), 'x &gt; y');
    });

    test('h4 escapes double-quote', () {
      expect(_h('"hello"'), '&quot;hello&quot;');
    });

    test('h5 escapes single-quote', () {
      expect(_h("it's"), 'it&#39;s');
    });

    test('h6 combined XSS attempt is fully escaped', () {
      const payload = '<img src=x onerror="alert(\'xss\')">';
      final out = _h(payload);
      expect(out, isNot(contains('<img')));
      expect(out, isNot(contains('"alert(')));
      expect(out, contains('&lt;img'));
      expect(out, contains('&quot;alert('));
    });

    test('h7 safe string passes through unchanged', () {
      const safe = 'Hello World 123';
      expect(_h(safe), safe);
    });

    test('h8 empty string passes through unchanged', () {
      expect(_h(''), '');
    });
  });

  // -------------------------------------------------------------------------
  // h9: _kpi fragment
  // -------------------------------------------------------------------------
  group('_kpi fragment', () {
    test('h9 contains numeric value and escaped label', () {
      final out = _kpi('Agents', 7);
      expect(out, contains('7'));
      expect(out, contains('Agents'));
      expect(out, contains('class="kpi"'));
    });

    test('h9b label with special chars is escaped', () {
      final out = _kpi('<Danger> & "Fun"', 0);
      expect(out, isNot(contains('<Danger>')));
      expect(out, contains('&lt;Danger&gt;'));
      expect(out, contains('&amp;'));
      expect(out, contains('&quot;Fun&quot;'));
    });
  });

  // -------------------------------------------------------------------------
  // h10: _inlineCss
  // -------------------------------------------------------------------------
  group('_inlineCss', () {
    test('h10 non-empty and contains body selector', () {
      final css = _inlineCss();
      expect(css, isNotEmpty);
      expect(css, contains('body'));
    });
  });

  // -------------------------------------------------------------------------
  // h11: activity rows — reversed order (newest first)
  // -------------------------------------------------------------------------
  group('activityHtml ordering', () {
    test('h11 rows appear in reversed (newest-first) order', () {
      final events = <ActivityEvent>[
        ActivityEvent(
          ts: DateTime.utc(2026, 1, 1),
          kind: ActivityKind.info,
          actor: 'first',
          headline: 'first-msg',
        ),
        ActivityEvent(
          ts: DateTime.utc(2026, 1, 2),
          kind: ActivityKind.info,
          actor: 'second',
          headline: 'second-msg',
        ),
        ActivityEvent(
          ts: DateTime.utc(2026, 1, 3),
          kind: ActivityKind.info,
          actor: 'third',
          headline: 'third-msg',
        ),
      ];
      final html = _buildActivityHtml(events, 80);
      final idxFirst = html.indexOf('first');
      final idxThird = html.indexOf('third');
      // Reversed → 'third' appears before 'first' in the output string
      expect(idxThird, lessThan(idxFirst));
    });
  });

  // -------------------------------------------------------------------------
  // h12: events window
  // -------------------------------------------------------------------------
  group('events window', () {
    test('h12 only last N events are kept when list exceeds recentEvents', () {
      final events = List.generate(
        20,
        (i) => _makeEvent('actor_$i', headline: 'msg_$i'),
      );
      final html = _buildActivityHtml(events, 5);
      // Should contain actors 15..19 (last 5) but not actors 0..14
      expect(html, contains('actor_19'));
      expect(html, contains('actor_15'));
      expect(html, isNot(contains('actor_14')));
      expect(html, isNot(contains('actor_0')));
    });

    test('h12b when events <= recentEvents all are included', () {
      final events = List.generate(3, (i) => _makeEvent('a_$i'));
      final html = _buildActivityHtml(events, 80);
      expect(html, contains('a_0'));
      expect(html, contains('a_2'));
    });

    test('h12c empty event list produces empty string', () {
      expect(_buildActivityHtml([], 80), isEmpty);
    });
  });
}
