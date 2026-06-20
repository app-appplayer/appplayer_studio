/// `dispatchLifecycleSlot` — generic lifecycle resolver shared by
/// every studio host. Chrome surfaces (Home buttons, Domain toolbars,
/// Tools-mode sub-tab actions) call into the host with a conceptual
/// slot id (e.g. `'project.new'`); the host resolves the slot against
/// the wiring bundle's `manifest.wiring.lifecycle[]` and invokes the
/// wired MCP tool.
///
/// The host owns the *resolution* of which bundle holds the wiring
/// table (typically the studio_seed bundle) and the *server* used to
/// dispatch the tool. Once it has those, the lookup + result-decoding
/// logic is identical across hosts, so we lift it here.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;

/// Resolve [slot] against the `wiring.lifecycle[]` array inside the
/// bundle at [mbdPath], then invoke the wired tool through [callTool].
///
/// * [mbdPath] — bundle whose `manifest.json` carries the wiring table.
/// * [slot] — conceptual slot id (matches `wiring.lifecycle[].slot`).
/// * [args] — forwarded verbatim to the resolved tool.
/// * [callTool] — host-supplied call into its MCP server (typically
///   `widget.boot.callTool`). The base helper has no knowledge
///   of the host's bundle registry / boot wiring.
///
/// Returns the tool's decoded JSON map on success, `{ok: true, text}`
/// when the tool returns plain text, `{ok: true}` when the tool
/// returns nothing, or `{ok: false, error}` when the slot isn't wired
/// or the dispatch failed. Mirrors the contract the chrome buttons
/// read to decide enabled state ("registered = exists" principle).
Future<Map<String, Object?>> dispatchLifecycleSlot({
  required String mbdPath,
  required String slot,
  required Map<String, dynamic> args,
  required Future<mk.KernelToolResult> Function(
    String name,
    Map<String, dynamic> args,
  )
  callTool,
}) async {
  String? toolName;
  try {
    final file = File(p.join(mbdPath, 'manifest.json'));
    if (file.existsSync()) {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is Map<String, dynamic>) {
        final wiring = raw['wiring'];
        if (wiring is Map<String, dynamic>) {
          final lifecycle = wiring['lifecycle'];
          if (lifecycle is List) {
            for (final e in lifecycle) {
              if (e is Map && e['slot'] == slot) {
                final t = e['tool'];
                if (t is String && t.isNotEmpty) {
                  toolName = t;
                  break;
                }
              }
            }
          }
        }
      }
    }
  } catch (_) {
    /* fall through */
  }
  if (toolName == null) {
    return <String, Object?>{'ok': false, 'error': 'slot $slot not wired'};
  }
  try {
    final result = await callTool(toolName, args);
    final content = result.content;
    if (content.isNotEmpty) {
      final first = content.first;
      if (first is mk.KernelTextContent) {
        final txt = first.text;
        try {
          final decoded = jsonDecode(txt);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {
          /* fall through */
        }
        return <String, Object?>{'ok': true, 'text': txt};
      }
    }
    return <String, Object?>{'ok': true};
  } catch (e) {
    return <String, Object?>{'ok': false, 'error': 'dispatch failed: $e'};
  }
}
