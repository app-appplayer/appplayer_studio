// UiView adapter that exposes the active inspector session as
// `mcp-ui:*` targets — the same target shape `CanonicalUiViewAdapter`
// uses for the editor's preview. Routes are inlined (no page loader
// required) since the session already cached every page resource
// during `_hydrate`.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:appplayer_ui_view/appplayer_ui_view.dart';

import 'inspector_session.dart';

const String _kMcpUiPrefix = 'mcp-ui:';

class InspectorUiViewAdapter implements UiViewAdapter {
  InspectorUiViewAdapter(this.session, {String? modeOverride})
    : _modeOverride = modeOverride;

  /// Active session. Recreate the adapter when `session` is replaced
  /// — `watch` controllers keep their identity per target so the
  /// existing UiView listeners stay subscribed.
  final InspectorSession session;

  String? _modeOverride;

  /// Force `theme.mode` on every emitted snapshot. `null` defers to the
  /// bundle's own theme. `'light'` / `'dark'` overrides per spec §5.
  void setModeOverride(String? mode) {
    if (mode == _modeOverride) return;
    _modeOverride = mode;
    pushUpdate();
  }

  final Map<String, StreamController<UiTargetUpdate>> _watchers =
      <String, StreamController<UiTargetUpdate>>{};

  /// Invoke after pulled session data changes (e.g. tool response
  /// fold updated state, server pushed a notification) so subscribed
  /// targets re-emit and the runtime rebuilds.
  void pushUpdate() {
    for (final entry in _watchers.entries) {
      final snap = _snapshotOf(entry.key);
      if (snap != null) entry.value.add(UiTargetUpdate(snap));
    }
  }

  @override
  Future<UiTargetSnapshot> fetch(String target) async {
    final snap = _snapshotOf(target);
    if (snap == null) {
      throw StateError('Unknown inspector target: $target');
    }
    return snap;
  }

  @override
  Stream<UiTargetUpdate> watch(String target) {
    final ctl = _watchers.putIfAbsent(
      target,
      () => StreamController<UiTargetUpdate>.broadcast(),
    );
    Future<void>.microtask(() {
      final snap = _snapshotOf(target);
      if (snap != null) ctl.add(UiTargetUpdate(snap));
    });
    return ctl.stream;
  }

  void dispose() {
    for (final ctl in _watchers.values) {
      ctl.close();
    }
    _watchers.clear();
  }

  UiTargetSnapshot? _snapshotOf(String target) {
    if (!target.startsWith(_kMcpUiPrefix)) return null;
    final tail = target.substring(_kMcpUiPrefix.length);
    final ui = session.appDefinition;
    if (ui == null) return null;

    Map<String, dynamic>? section;
    if (tail == 'app') {
      // Keep routes as `ui://pages/<id>` string URIs — the runtime's
      // 0.4.x validator only accepts string route values; the host
      // resolves them through the `pageLoader` callback wired into
      // `McpUiRuntimePort`.
      final flat = Map<String, dynamic>.from(ui);
      flat.remove('pages');
      section = flat;
    } else if (tail == 'dashboard') {
      final dash = ui['dashboard'];
      final content = dash is Map ? dash['content'] : null;
      if (content is! Map) return null;
      // Synthesise a single-route App that points to a sentinel URI
      // — `pageLoader` recognises the sentinel and returns
      // `{type: page, content: dashboard.content}`.
      section = <String, dynamic>{
        'type': 'application',
        if (ui['theme'] is Map) 'theme': ui['theme'],
        if (ui['templates'] is Map) 'templates': ui['templates'],
        'routes': <String, dynamic>{'/': '__inspector_dashboard__'},
        'initialRoute': '/',
      };
    } else if (tail.startsWith('page/')) {
      final id = tail.substring(5);
      if (session.pages[id] == null) return null;
      section = <String, dynamic>{
        'type': 'application',
        if (ui['theme'] is Map) 'theme': ui['theme'],
        if (ui['templates'] is Map) 'templates': ui['templates'],
        'routes': <String, dynamic>{'/': 'ui://pages/$id'},
        'initialRoute': '/',
      };
    } else {
      return null;
    }

    if (_modeOverride != null) {
      final theme = section['theme'];
      final updated =
          theme is Map ? Map<String, dynamic>.from(theme) : <String, dynamic>{};
      updated['mode'] = _modeOverride;
      section['theme'] = updated;
    }

    final encoded = jsonEncode(section);
    final hash = sha256.convert(utf8.encode(encoded)).toString();
    return UiTargetSnapshot(
      target: target,
      data: section,
      sourceHash: hash,
      fetchedAt: DateTime.now(),
      source: 'inspector',
    );
  }
}
