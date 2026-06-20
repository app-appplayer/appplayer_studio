/// Studio convention — the chat manager for any bundle is the first
/// agent in its `manifest.json` whose `role == 'manager'`. No separate
/// `chat.agent` declaration; no host-side hard-coded id. Built-ins and
/// user bundles follow the same rule: the host reads the manifest
/// each tab activates against and looks up the manager.
///
/// Returns the fully-prefixed exposed id (`<exposedShortId>.<rawId>`
/// when the manifest id is local-only) or the verbatim id when the
/// manifest already supplies a dotted namespace. Null when the
/// manifest is missing / unreadable / has no manager-role entry.
library;

import 'dart:convert';
import 'dart:io';

String? readSeedChatManager({
  required String manifestPath,
  required String exposedShortId,
}) {
  final file = File(manifestPath);
  if (!file.existsSync()) return null;
  try {
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map<String, dynamic>) return null;
    final agentsRaw = raw['agents'];
    List? agents;
    if (agentsRaw is Map<String, dynamic>) {
      agents = agentsRaw['agents'] as List?;
    } else if (agentsRaw is List) {
      agents = agentsRaw;
    }
    if (agents == null) return null;
    for (final a in agents) {
      if (a is! Map<String, dynamic>) continue;
      if (a['role'] != 'manager') continue;
      final id = a['id'] as String?;
      if (id == null || id.isEmpty) continue;
      if (id.contains('.')) return id;
      if (exposedShortId.isEmpty) return id;
      return '$exposedShortId.$id';
    }
    return null;
  } catch (_) {
    return null;
  }
}
