/// Manifest → chrome readers shared by every host that runs a bundle as an
/// app: the lifecycle state the project header shows
/// (`wiring.lifecycleStateBindings`), the title / status bar text
/// (`wiring.titlebar` / `wiring.statusbar` templates) and the chat slash
/// chips (`chat.slashCommands`). One implementation so a bundle's chrome
/// reads the same in every host.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../chat/chat_slash_hint.dart';
import 'chrome_bridge.dart';

Map<String, dynamic>? _manifest(String mbdPath) {
  if (mbdPath.isEmpty) return null;
  try {
    final file = File(p.join(mbdPath, 'manifest.json'));
    if (!file.existsSync()) return null;
    final raw = jsonDecode(file.readAsStringSync());
    return raw is Map<String, dynamic> ? raw : null;
  } catch (_) {
    return null;
  }
}

/// The bundle's `manifest.wiring.lifecycleStateBindings` resolved against
/// [liveState] (the app's runtime state):
///
/// ```json
/// "wiring": {
///   "lifecycleStateBindings": {
///     "projectName": "{{currentProject}}",
///     "hasProject": "{{currentProject != ''}}",
///     "dirty": "{{isDirty}}",
///     "canUndo": "{{canUndo}}",
///     "canRedo": "{{canRedo}}"
///   }
/// }
/// ```
///
/// Missing keys fall through to the `DomainLifecycleState.empty()`
/// defaults. Returns `null` when the bundle declares no bindings.
DomainLifecycleState? readManifestLifecycleBindings(
  String mbdPath,
  Map<String, Object?> liveState,
) {
  final wiring = _manifest(mbdPath)?['wiring'];
  if (wiring is! Map<String, dynamic>) return null;
  final bindings = wiring['lifecycleStateBindings'];
  if (bindings is! Map<String, dynamic> || bindings.isEmpty) return null;

  String? readString(String key) {
    final raw = bindings[key];
    if (raw is! String) return raw?.toString();
    return evalChromeBinding(raw, liveState)?.toString();
  }

  bool readBool(String key) {
    final raw = bindings[key];
    if (raw is bool) return raw;
    if (raw is! String) return false;
    final v = evalChromeBinding(raw, liveState);
    if (v is bool) return v;
    if (v is String) return v.isNotEmpty && v != 'false' && v != '0';
    if (v is num) return v != 0;
    return v != null;
  }

  return DomainLifecycleState(
    hasProject: readBool('hasProject'),
    dirty: readBool('dirty'),
    canUndo: readBool('canUndo'),
    canRedo: readBool('canRedo'),
    canCompareChannels: readBool('canCompareChannels'),
    projectName: readString('projectName'),
  );
}

/// Evaluates one chrome binding against [state]: a bare `{{key}}` lookup,
/// `{{key != ''}}` / `{{key == ''}}`, or `{{!key}}`. A string without a
/// `{{...}}` wrapper is returned as is.
Object? evalChromeBinding(String src, Map<String, Object?> state) {
  final trimmed = src.trim();
  final m = RegExp(r'^\{\{(.+)\}\}$').firstMatch(trimmed);
  if (m == null) return trimmed;
  final expr = m.group(1)!.trim();
  final neq = RegExp(r"^(\w+)\s*!=\s*''$").firstMatch(expr);
  if (neq != null) {
    final v = state[neq.group(1)!];
    if (v == null) return false;
    if (v is String) return v.isNotEmpty;
    return true;
  }
  final eq = RegExp(r"^(\w+)\s*==\s*''$").firstMatch(expr);
  if (eq != null) {
    final v = state[eq.group(1)!];
    if (v == null) return true;
    if (v is String) return v.isEmpty;
    return false;
  }
  if (expr.startsWith('!')) {
    final v = state[expr.substring(1).trim()];
    return v == null || v == false || v == '' || v == 0;
  }
  return state[expr];
}

/// Resolves `{{path}}` tokens in a chrome text [template] against [state].
/// Nested paths (`{{a.b.c}}`) walk the map; missing keys leave the
/// placeholder empty. Plain string interpolation — no expressions.
String interpolateChromeText(String template, Map<String, Object?> state) {
  return template.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (m) {
    final raw = m.group(1)?.trim() ?? '';
    if (raw.isEmpty) return '';
    Object? cursor = state;
    for (final seg in raw.split('.')) {
      if (cursor is Map) {
        cursor = cursor[seg];
      } else {
        cursor = null;
        break;
      }
    }
    return cursor == null ? '' : cursor.toString();
  });
}

/// The bundle's `manifest.chat.slashCommands[]` as chat chips:
/// `{ command: '/foo', template?, description?, tool?, arguments? }`.
List<ChatSlashHint> readManifestSlashHints(String mbdPath) {
  final chat = _manifest(mbdPath)?['chat'];
  if (chat is! Map<String, dynamic>) return const <ChatSlashHint>[];
  final cmds = chat['slashCommands'];
  if (cmds is! List) return const <ChatSlashHint>[];
  return <ChatSlashHint>[
    for (final c in cmds)
      if (c is Map<String, dynamic> && c['command'] is String)
        ChatSlashHint(
          c['command'] as String,
          c['template'] as String?,
          c['description'] as String?,
          c['tool'] as String?,
          (c['arguments'] is Map)
              ? Map<String, dynamic>.from(c['arguments'] as Map)
              : null,
        ),
  ];
}
