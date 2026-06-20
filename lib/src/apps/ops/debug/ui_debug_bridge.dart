/// UI debugging bridge for external MCP-driven inspection.
///
/// External LLM (= MCP client) drives the GUI like a human:
///   - capture the current screen (PNG base64) — including any open dialog,
///     because [capturePngBase64] images the whole render view (root-navigator
///     overlays included), not just the Ops shell [captureKey] boundary
///   - navigate to any sidebar route (writes to [shellRouteProvider])
///   - read active route / active workspace
///
/// Phase B (separate round): chat input/output, dialog open, page state
/// dump.
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:appplayer_studio/builtin_api.dart' show AgentAxis;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../init/knowledge_init.dart';
import '../registries/member_registry.dart' show AgentMember;
import '../state/providers.dart';

class UiDebugBridge {
  UiDebugBridge._();

  /// Anchors a [RepaintBoundary] around the Ops shell — used only as the
  /// fallback capture surface. The primary path images the whole render
  /// view (see [capturePngBase64]) so root-navigator dialogs, which mount
  /// above this boundary, are still captured.
  static final captureKey = GlobalKey();

  static WidgetRef? _ref;

  /// Wire the bridge to the live booted ProviderScope's WidgetRef.
  /// Called from a Consumer mounted just under the booted ProviderScope
  /// so it sees the same overrides MCP tools need to read.
  static void attach(WidgetRef ref) {
    _ref = ref;
  }

  /// Capture the live UI as a base64 PNG. `pixelRatio` 1.5 keeps the
  /// payload reasonable for chat-context use while remaining legible.
  static Future<String?> capturePngBase64({double pixelRatio = 1.5}) async {
    // `showDialog` mounts under the host root navigator, which sits ABOVE
    // the Ops shell's `captureKey` RepaintBoundary — a boundary-scoped
    // capture silently drops dialogs/overlays (the Ops shell owns no
    // Navigator it could anchor a higher boundary above). Capture the
    // whole render view so any open dialog is included; fall back to the
    // shell boundary only when the root layer is not an OffsetLayer.
    final views = WidgetsBinding.instance.renderViews;
    if (views.isNotEmpty) {
      final renderView = views.first;
      final layer = renderView.layer;
      if (layer is OffsetLayer) {
        final image = await layer.toImage(
          renderView.paintBounds,
          pixelRatio: pixelRatio,
        );
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes != null) {
          return base64Encode(bytes.buffer.asUint8List());
        }
      }
    }
    final ctx = captureKey.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary) return null;
    final image = await ro.toImage(pixelRatio: pixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return null;
    return base64Encode(bytes.buffer.asUint8List());
  }

  static String? activeRoute() {
    final r = _ref;
    if (r == null) return null;
    return r.read(shellRouteProvider);
  }

  static String? activeWorkspaceId() {
    final r = _ref;
    if (r == null) return null;
    return r.read(activeWorkspaceIdProvider);
  }

  /// Same effect as a human clicking a sidebar item — writes
  /// [shellRouteProvider]. The capture taken on the next frame shows the
  /// new page.
  static void navigate(String route) {
    final r = _ref;
    if (r == null) return;
    r.read(shellRouteProvider.notifier).state = route;
  }

  static KnowledgeInit? init() {
    final r = _ref;
    if (r == null) return null;
    try {
      return r.read(knowledgeInitProvider);
    } catch (_) {
      return null;
    }
  }

  /// JSON-friendly snapshot of the active page's data — what an external
  /// LLM would see by reading the GUI. Branch by `activeRoute`:
  ///   - members  → list of members in active workspace (id · kind ·
  ///     displayName · skillIds count)
  ///   - knowledge → fact counts + type histogram + entity histogram
  ///   - skills / profiles / philosophies → IntegratedAxisEntry summary
  ///     (pool count + owned count + sample entries)
  ///   - tasks / processes → registry summary
  ///   - other → just the route + ws id
  static Future<Map<String, Object?>> pageStateSnapshot() async {
    final r = _ref;
    if (r == null) return {'attached': false};
    final route = r.read(shellRouteProvider);
    final wsId = r.read(activeWorkspaceIdProvider);
    final base = <String, Object?>{'route': route, 'workspaceId': wsId};
    if (wsId == null) return base;
    final init = _readInit(r);
    if (init == null) return base..['error'] = 'KnowledgeInit unavailable';
    switch (route) {
      case 'members':
        final members = await init.registries.member.listForWorkspace(wsId);
        base['members'] = [
          for (final m in members)
            {
              'id': m.id,
              'kind': m.kind.name,
              'displayName': m.displayName,
              if (m is AgentMember) 'agentId': m.agentId,
              if (m is AgentMember) 'skillIds': m.skillIds,
              if (m is AgentMember) 'profileRef': m.profileRef,
              if (m is AgentMember) 'philosophyRef': m.philosophyRef,
            },
        ];
        break;
      case 'knowledge':
        final facts = await init.registries.knowledge.query(
          '',
          workspaceId: wsId,
          limit: 500,
        );
        final types = <String, int>{};
        final entities = <String, int>{};
        for (final f in facts) {
          types[f.type] = (types[f.type] ?? 0) + 1;
          final eid = f.entityId;
          if (eid != null && eid.isNotEmpty) {
            entities[eid] = (entities[eid] ?? 0) + 1;
          }
        }
        base['factCount'] = facts.length;
        base['types'] = types;
        base['entities'] = entities;
        break;
      case 'skills':
      case 'profiles':
      case 'philosophies':
        final axis =
            route == 'skills'
                ? AgentAxis.skill
                : route == 'profiles'
                ? AgentAxis.profile
                : AgentAxis.philosophy;
        if (init.system.isAgentSubsystemActivated) {
          final entries = await init.system.agents.listIntegrated(wsId, axis);
          base['poolCount'] = entries.where((e) => e.isPool).length;
          base['ownedCount'] = entries.where((e) => e.isAgentOwned).length;
          base['entries'] = [
            for (final e in entries.take(40))
              {
                'source': e.source.encode(),
                'displayLabel': e.displayLabel,
                'ownerAgentId': e.ownerAgentId,
                'lineage': e.lineage,
              },
          ];
        }
        break;
      case 'tasks':
        final tasks = await init.registries.task.list(wsId: wsId);
        base['taskCount'] = tasks.length;
        base['tasks'] = [
          for (final t in tasks.take(40))
            {'id': t.id, 'title': t.title, 'state': t.state.name},
        ];
        break;
      case 'processes':
        final procs = await init.registries.process.list(wsId: wsId);
        base['processCount'] = procs.length;
        base['processes'] = [
          for (final p in procs.take(40)) {'id': p.id, 'title': p.title},
        ];
        break;
    }
    return base;
  }

  static KnowledgeInit? _readInit(WidgetRef r) {
    try {
      return r.read(knowledgeInitProvider);
    } catch (_) {
      return null;
    }
  }

  /// Push an agent-detail dialog request — picked up by the listener
  /// mounted in main.dart, which calls [showAgentDetailDialog] on the
  /// next frame. The `ts` field guarantees consecutive identical requests
  /// still trigger a fresh dialog (StateProvider equality is by record).
  static bool requestOpenAgentDialog(String agentId, {String? displayName}) {
    final r = _ref;
    if (r == null) return false;
    r.read(dialogRequestProvider.notifier).state = DialogRequest(
      agentId: agentId,
      displayName: displayName ?? agentId,
      ts: DateTime.now().microsecondsSinceEpoch,
    );
    return true;
  }
}

// `ChatSendRequest` / `chatRequestProvider` / `chatHistoryProvider`
// retired — chat surface collapsed onto the host's shared chat panel
// (MOD-APPS-007). Ops's own `ChatPane` widget and its automation
// providers were removed together with the `ui_chat_send` /
// `ui_chat_history` MCP tools.

/// Pending dialog request payload pumped through [dialogRequestProvider].
class DialogRequest {
  const DialogRequest({
    required this.agentId,
    required this.displayName,
    required this.ts,
  });

  final String agentId;
  final String displayName;
  final int ts;
}

final dialogRequestProvider = StateProvider<DialogRequest?>((_) => null);

/// Stateful Consumer mounted just under the booted ProviderScope so its
/// `ref` sees [knowledgeInitProvider] / [shellRouteProvider] /
/// [activeWorkspaceIdProvider] overrides. Handing the ref to
/// [UiDebugBridge.attach] lets MCP tool handlers (running outside the
/// widget tree) read and write provider state.
class UiDebugAttacher extends ConsumerStatefulWidget {
  const UiDebugAttacher({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<UiDebugAttacher> createState() => _UiDebugAttacherState();
}

class _UiDebugAttacherState extends ConsumerState<UiDebugAttacher> {
  @override
  void initState() {
    super.initState();
    UiDebugBridge.attach(ref);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
