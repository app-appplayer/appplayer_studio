import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../shell/app_theme.dart';
import '../shell/tokens.dart';
import 'chat_controller.dart';
import 'chat_slash_hint.dart';
import 'chat_turn.dart';
import 'model_option.dart';

/// Left column chat panel — header + scrollable feed of patch cards /
/// prompt bubbles + composer.
///
/// Generic over the host: model catalog (`modelOptions`) and layer
/// color / label resolution (`layerColorBuilder` + `layerLabelBuilder`)
/// are passed in by the domain tool.

/// Compact model picker pill — vibe showMenu pattern, sits in the
/// chat header next to the turn count + clear button. The pill shows
/// the active model's label, and tapping opens a popup of the catalog
/// entries. Selection round-trips through `onModelChange` so the
/// shell can update settings + re-init the LLM provider.
class _ModelChip extends StatelessWidget {
  const _ModelChip({
    required this.currentAgentId,
    required this.currentModelId,
    required this.modelOptions,
    required this.agents,
    this.effectiveModelId,
    this.onAgentChange,
  });

  /// Chip — surfaces the bond between the active chat agent and the model
  /// it routes to. Tapping opens the domain roster; picking an agent routes
  /// the next message to it (via [onAgentChange]). The per-agent model is
  /// still set in Settings → Domain → Agents; the resolved model id arrives
  /// via [currentModelId].
  final String? currentAgentId;
  final String? currentModelId;
  final List<VibeModelOption> modelOptions;

  /// Route the next message to the picked agent. Null = read-only (the
  /// roster popup just displays the agents, no selection).
  final ValueChanged<String>? onAgentChange;

  /// Effective LLM modelId the kernel actually dispatches through.
  /// When non-null and different from [currentModelId], the chip
  /// surfaces the fallback inline (`declared → effective`).
  final String? effectiveModelId;

  /// The full agent roster of the active domain — surfaced as a
  /// read-only popup when the user taps the chip so they can see every
  /// agent the tab exposes (not just the active manager).
  final List<VibeChatAgentEntry> agents;

  VibeModelOption get _resolved {
    final id = currentModelId;
    for (final m in modelOptions) {
      if (m.id == id) return m;
    }
    return modelOptions.first;
  }

  /// Short provider tag rendered on the second line of the chip so the
  /// user can tell at a glance which surface the model is calling
  /// (Anthropic / OpenAI / Gemini API vs. Claude Code subscription).
  /// Falls back to the raw provider id when unmapped.
  static String _providerTag(String? provider) {
    switch (provider) {
      case 'anthropic':
        return 'Anthropic API';
      case 'openai':
        return 'OpenAI API';
      case 'gemini':
        return 'Gemini API';
      case 'claude_code':
        return 'Claude Code · subscription';
      case null:
      case '':
        return '';
      default:
        return provider;
    }
  }

  /// Manifest agent id stripped of its namespace prefix
  /// (`app_builder.manager` → `manager`).
  static String _rawId(String fullId) {
    final dot = fullId.lastIndexOf('.');
    return dot < 0 ? fullId : fullId.substring(dot + 1);
  }

  /// Catalog model label keyed by id; falls back to the raw id when
  /// the model isn't in the host catalog.
  String _modelLabelOf(String? modelId) {
    if (modelId == null || modelId.isEmpty) return '';
    for (final m in modelOptions) {
      if (m.id == modelId) return m.label;
    }
    return modelId;
  }

  /// One-line `<rawId> · <declared>` or `<rawId> · <declared> →
  /// <effective>` when the agent's declared model has no adapter and
  /// the kernel falls back to a different one. The active agent and
  /// every roster sibling share the same kernel fallback (pool first
  /// entry), so the indicator applies to every row, not just the
  /// active one.
  String _rosterLine(VibeChatAgentEntry a) {
    final raw = _rawId(a.id);
    final declared = _modelLabelOf(a.modelId);
    if (effectiveModelId != null &&
        a.modelId != null &&
        effectiveModelId != a.modelId) {
      return '$raw · $declared → ${_modelLabelOf(effectiveModelId)}';
    }
    return '$raw · $declared';
  }

  Future<void> _showRoster(BuildContext context) async {
    if (agents.isEmpty) return;
    final c = VibeTokens.colorOf(context);
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlaySize = overlayBox.size;
    final offset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final size = box.size;
    final anchor = Rect.fromLTWH(
      offset.dx,
      offset.dy + size.height + 6,
      size.width,
      0,
    );
    final selected = await showMenu<String>(
      context: context,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      useRootNavigator: true,
      menuPadding: EdgeInsets.zero,
      color: c.elevated,
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
        side: BorderSide(color: c.borderStrong),
      ),
      position: RelativeRect.fromRect(anchor, Offset.zero & overlaySize),
      items: <PopupMenuEntry<String>>[
        for (final a in agents)
          PopupMenuItem<String>(
            value: a.id,
            height: 28,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(
                _rosterLine(a),
                style: vibeMono(
                  size: 11,
                  color: a.id == currentAgentId ? c.mint : c.textPrimary,
                ),
              ),
            ),
          ),
      ],
    );
    if (selected != null && selected != currentAgentId) {
      onAgentChange?.call(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final m = _resolved;
    final agentRaw =
        (currentAgentId == null || currentAgentId!.isEmpty)
            ? '—'
            : _rawId(currentAgentId!);
    final declaredLabel = m.label;
    final fallback =
        effectiveModelId != null &&
        currentModelId != null &&
        effectiveModelId != currentModelId;
    final line =
        fallback
            ? '$agentRaw · $declaredLabel → ${_modelLabelOf(effectiveModelId)}'
            : '$agentRaw · $declaredLabel';
    final tooltipMessage =
        fallback
            ? '$agentRaw declared $declaredLabel · falling back to '
                '${_modelLabelOf(effectiveModelId)}\n'
                '(no API key for this provider — add it in Settings → LLM)'
            : '$line\n(edit in Settings → Domain → Agents)';
    return Tooltip(
      message: tooltipMessage,
      child: InkWell(
        onTap: () => _showRoster(context),
        borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
            border: Border.all(color: c.borderDefault),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: vibeMono(size: 11, color: c.textPrimary),
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down, size: 14, color: c.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

class ChatPanel extends StatefulWidget {
  const ChatPanel({
    super.key,
    required this.controller,
    required this.modelOptions,
    required this.layerColorBuilder,
    required this.layerLabelBuilder,
    this.health,
    this.onQuickFix,
    this.onSlashCommand,
    this.currentModelId,
    this.onModelChange,
    this.slashHints,
    this.onDirectDispatch,
    this.agentsOverride,
    this.currentAgentIdOverride,
    this.onAgentSwitch,
    this.effectiveModelId,
  });

  /// Switch the active conversation to the picked roster agent. When supplied,
  /// selecting an agent in the chip routes here (the host re-keys the panel to
  /// that agent's conversation) instead of only flipping the local
  /// `controller.selectedAgentId` (next-message routing). Null = legacy
  /// behaviour.
  final void Function(String agentId)? onAgentSwitch;

  /// Effective LLM model id — the adapter currently wired into the
  /// kernel pool (`settings.llmModel`). When this differs from
  /// `currentModelId` (the active agent's declared model), the chip
  /// renders a `declared → effective` fallback indicator so the user
  /// can tell a per-agent assignment isn't actually running.
  final String? effectiveModelId;

  /// Active-domain agent roster pulled from `AgentHost` (filtered by
  /// the active namespace). When supplied, the header's read-only
  /// model chip uses this list instead of `controller.agents`. Null
  /// keeps the legacy controller-driven behaviour.
  final List<VibeChatAgentEntry>? agentsOverride;

  /// Currently-active chat agent id from the host (`chromeBridge
  /// .activeChatAgentId`). When supplied, the header surfaces this
  /// instead of `controller.selectedAgentId` so tab switches are
  /// reflected even when the in-panel agent dropdown wasn't touched.
  final String? currentAgentIdOverride;

  /// Override the composer's slash command catalog. Null falls back to
  /// the legacy hardcoded list (kept for `vibe_app_builder` parity);
  /// universal `vibe_studio` passes a freshly computed list per active
  /// tab via the chrome bridge.
  final List<ChatSlashHint>? slashHints;

  /// Direct-dispatch handler — fired when the user taps a slash chip
  /// whose hint declares a `tool` field. Bypasses the LLM. Hosts wire
  /// this to their MCP dispatcher; null collapses every chip back to
  /// template-insert behavior.
  final Future<void> Function(ChatSlashHint hint)? onDirectDispatch;
  final VibeChatController controller;

  /// LLM model catalog rendered in the header model chip dropdown.
  /// Domain tools pass their own list (vibe_app_builder = 5 Anthropic
  /// models, etc.).
  final List<VibeModelOption> modelOptions;

  /// Maps `ChatTurn.layer` (Object?) to the stripe colour on the
  /// patch card's left edge.
  final Color Function(Object? layer) layerColorBuilder;

  /// Maps `ChatTurn.layer` (non-null) to a short label ("App",
  /// "Theme", ...) shown before "patched". Returning null suppresses
  /// the prefix.
  final String? Function(Object layer) layerLabelBuilder;

  /// Active LLM model id (matches `VibeSettings.llmModel`). When null
  /// the chat falls back to the catalog default. Drives the header
  /// model chip's display text.
  final String? currentModelId;

  /// Callback fired when the user picks a model from the chip's
  /// dropdown. Shell updates settings + reinitializes the LLM
  /// provider on the next call. Null disables the picker (chip
  /// renders dimmed and non-interactive).
  final ValueChanged<String>? onModelChange;

  /// Slash-command dispatcher. When the composer input starts with
  /// `/`, the panel parses `command + args` and asks the shell to
  /// run it through `BuildToolsDispatcher` directly — no LLM
  /// round-trip. The result is appended to chat as a system note.
  /// Returns the dispatched tool name on success, `null` when the
  /// command is unknown (panel falls back to LLM ask).
  final Future<String?> Function(String input)? onSlashCommand;

  /// Latest health snapshot from the shell (debounced ~800ms after
  /// every canonical change). Null while a project isn't open or
  /// the first check hasn't completed yet — `_HealthBar` renders
  /// a neutral resting state in that case.
  final Map<String, dynamic>? health;

  /// One-click quick-fix dispatch. The shell wires this to
  /// `BuildToolsDispatcher` so chat-side action buttons can run a
  /// repair tool without going through the LLM. Action ids:
  ///   - `a11y_quick_fix`     → repairs minFontSize / touchTarget
  ///   - `asset_audit_apply`  → migrates invalid asset entries
  ///   - `extract_i18n`       → lifts the focused page's literal
  ///                            strings to /ui/i18n
  /// Null hides the button bar (no project / no shell wiring).
  final Future<void> Function(String actionId)? onQuickFix;

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(right: BorderSide(color: c.borderDefault)),
      ),
      child: AnimatedBuilder(
        animation: widget.controller,
        builder:
            (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _Header(
                  turnCount: widget.controller.turns.length,
                  onClear:
                      widget.controller.turns.isEmpty
                          ? null
                          : () => _confirmClear(context),
                  currentModelId: widget.currentModelId,
                  effectiveModelId: widget.effectiveModelId,
                  onModelChange: widget.onModelChange,
                  modelOptions: widget.modelOptions,
                  currentAgentId:
                      widget.currentAgentIdOverride ??
                      widget.controller.selectedAgentId,
                  agents: widget.agentsOverride ?? widget.controller.agents,
                  // Picking an agent opens a conversation with it (host re-keys
                  // the panel to that agent's chat). Falls back to flipping the
                  // local routing target when no host switch is wired.
                  onAgentChange:
                      widget.onAgentSwitch ??
                      (id) => widget.controller.selectedAgentId = id,
                ),
                _HealthBar(snapshot: widget.health),
                _QuickFixBar(
                  snapshot: widget.health,
                  onAction: widget.onQuickFix,
                ),
                Expanded(
                  child: _Feed(
                    turns: widget.controller.turns,
                    busy: widget.controller.busy,
                    onDeleteTurn: widget.controller.removeTurn,
                    layerColorBuilder: widget.layerColorBuilder,
                    layerLabelBuilder: widget.layerLabelBuilder,
                  ),
                ),
                _Composer(
                  controller: _input,
                  busy: widget.controller.busy,
                  onSubmit: _submit,
                  history: <String>[
                    for (final t in widget.controller.turns)
                      if (t.role == 'user') t.text,
                  ],
                  slashHints: widget.slashHints,
                  onDirectDispatch: widget.onDirectDispatch,
                ),
              ],
            ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Clear conversation?'),
            content: const Text(
              'Removes every turn from the chat panel. The on-disk '
              'chat.jsonl is unaffected.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Clear'),
              ),
            ],
          ),
    );
    if (ok == true) widget.controller.clear();
  }

  void _submit(String text) {
    final v = text.trim();
    if (v.isEmpty) return;
    _input.clear();
    if (v.startsWith('/') && widget.onSlashCommand != null) {
      // Echo the prompt as a user turn so the chat history shows
      // intent, then route the slash command through the shell.
      widget.controller.appendTurn(ChatTurn(role: 'user', text: v));
      // ignore: discarded_futures
      widget.onSlashCommand!(v);
      return;
    }
    widget.controller.ask(v);
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.turnCount,
    required this.onClear,
    required this.modelOptions,
    this.currentModelId,
    this.effectiveModelId,
    this.onModelChange,
    this.currentAgentId,
    this.onAgentChange,
    this.agents = const <VibeChatAgentEntry>[],
  });
  final int turnCount;
  final VoidCallback? onClear;
  final List<VibeModelOption> modelOptions;
  final String? currentModelId;
  final String? effectiveModelId;
  final ValueChanged<String>? onModelChange;
  final String? currentAgentId;
  final ValueChanged<String>? onAgentChange;
  final List<VibeChatAgentEntry> agents;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VibeTokens.space3,
        vertical: VibeTokens.space2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('Chat', style: Theme.of(context).textTheme.titleLarge),
                  if (turnCount > 0) ...<Widget>[
                    const SizedBox(width: 8),
                    Text(
                      '$turnCount',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: c.textTertiary),
                    ),
                  ],
                ],
              ),
            ],
          ),
          // Single chip — combines the active agent (raw id) with its
          // model in one row, dropdown surfaces the rest of the
          // domain's roster (`AgentChip` consolidated away).
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Align(
                alignment: Alignment.centerRight,
                child: _ModelChip(
                  currentAgentId: currentAgentId,
                  currentModelId: currentModelId,
                  effectiveModelId: effectiveModelId,
                  modelOptions: modelOptions,
                  agents: agents,
                  onAgentChange: onAgentChange,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip:
                onClear == null ? 'Nothing to clear' : 'Clear conversation',
            icon: Icon(
              Icons.cleaning_services_outlined,
              size: 16,
              color: c.textSecondary,
            ),
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}

/// Agent dropdown chip — same showMenu pattern as `_ModelChip`. Sits in
/// the chat header next to the model chip. Lets the user route the
/// next message to a different agent (manager · ux-designer · composer
/// · reviewer · debugger · curator · builder). Hidden when `agents` is
/// empty (no FlowBrain agent host booted).
class _AgentChip extends StatelessWidget {
  const _AgentChip({
    required this.currentAgentId,
    required this.agents,
    required this.onChange,
  });

  final String? currentAgentId;
  final List<VibeChatAgentEntry> agents;
  final ValueChanged<String>? onChange;

  VibeChatAgentEntry get _resolved {
    final id = currentAgentId;
    for (final a in agents) {
      if (a.id == id) return a;
    }
    return agents.first;
  }

  Future<void> _open(BuildContext context) async {
    if (onChange == null) return;
    final c = VibeTokens.colorOf(context);
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlaySize = overlayBox.size;
    final offset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final size = box.size;
    final anchor = Rect.fromLTWH(
      offset.dx,
      offset.dy + size.height + 6,
      size.width,
      0,
    );
    final selected = await showMenu<String>(
      context: context,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      useRootNavigator: true,
      menuPadding: EdgeInsets.zero,
      color: c.elevated,
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 220),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
        side: BorderSide(color: c.borderStrong),
      ),
      position: RelativeRect.fromRect(anchor, Offset.zero & overlaySize),
      items: <PopupMenuEntry<String>>[
        for (final a in agents)
          PopupMenuItem<String>(
            value: a.id,
            height: 36,
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: () => Navigator.of(context).pop(a.id),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Text(
                  a.displayName,
                  style: vibeMono(
                    size: 12,
                    color: a.id == currentAgentId ? c.mint : c.textPrimary,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    if (selected != null && selected != currentAgentId) {
      onChange!(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final a = _resolved;
    return InkWell(
      onTap: onChange == null ? null : () => _open(context),
      borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 110),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          border: Border.all(color: c.borderDefault),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.smart_toy_outlined, size: 12, color: c.textSecondary),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                a.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: vibeMono(
                  size: 11,
                  color: onChange == null ? c.textTertiary : c.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 14, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Compact bundle health pill — sits between Header and Feed so the
/// author always sees current status without leaving the chat.
/// Shape: status icon + count breakdown + Tooltip with detail.
/// Renders a neutral "—" pill when the health snapshot isn't ready
/// (no project, first run pending). Counts come from
/// `BuildToolsDispatcher.health_check`, refreshed off the canonical
/// change stream with an 800ms debounce.
class _HealthBar extends StatelessWidget {
  const _HealthBar({required this.snapshot});
  final Map<String, dynamic>? snapshot;

  /// Derive a letter grade (A–F) from the health summary using the
  /// same 5-axis rubric the `grade()` MCP tool exposes. Avoids an
  /// extra round-trip — the chat-side bar can show the letter live
  /// off the same snapshot the status pill consumes.
  String? _letterFromSummary(Map summary) {
    int penalty(num issues, {num cap = 20, num perIssue = 4}) {
      final p = (issues * perIssue).clamp(0, cap).toInt();
      return 20 - p;
    }

    final validity = penalty(
      ((summary['specIssues'] ?? 0) as int) +
          ((summary['wiringIssues'] ?? 0) as int),
    );
    final a11y = penalty(
      ((summary['a11yFails'] ?? 0) as int) * 2 +
          ((summary['a11yWarns'] ?? 0) as int),
    );
    final assets = penalty((summary['invalidAssets'] ?? 0) as int, perIssue: 5);
    final state = penalty(
      ((summary['undefinedState'] ?? 0) as int) * 2 +
          ((summary['unusedState'] ?? 0) as int),
    );
    final tokens = penalty((summary['deadTokens'] ?? 0) as int, perIssue: 3);
    final total = validity + a11y + assets + state + tokens;
    return total >= 90
        ? 'A'
        : total >= 80
        ? 'B'
        : total >= 70
        ? 'C'
        : total >= 60
        ? 'D'
        : 'F';
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final s = snapshot;
    final status = s?['status'] as String?;
    final summary =
        s?['summary'] is Map ? s!['summary'] as Map : const <String, dynamic>{};
    Color pillColor;
    Color borderColor;
    IconData icon;
    String label;
    if (s == null) {
      pillColor = c.surface2;
      borderColor = c.borderDefault;
      icon = Icons.remove_circle_outline;
      label = '—';
    } else if (status == 'pass') {
      pillColor = c.surface2;
      borderColor = c.mint;
      icon = Icons.check_circle_outline;
      label = 'all green';
    } else if (status == 'warn') {
      pillColor = c.surface2;
      borderColor = const Color(0xFFE8B86A);
      icon = Icons.error_outline;
      final advisory =
          (summary['a11yWarns'] ?? 0) +
          (summary['unusedState'] ?? 0) +
          (summary['deadTokens'] ?? 0);
      label = '$advisory advisory';
    } else {
      pillColor = c.surface2;
      borderColor = c.coral;
      icon = Icons.error_outline;
      final blocking =
          (summary['specIssues'] ?? 0) +
          (summary['wiringIssues'] ?? 0) +
          (summary['a11yFails'] ?? 0) +
          (summary['invalidAssets'] ?? 0) +
          (summary['undefinedState'] ?? 0);
      label = '$blocking blocking';
    }
    final detail =
        s == null
            ? 'No health snapshot yet — open a project and edit anything.'
            : <String>[
              if ((summary['specIssues'] ?? 0) > 0)
                '${summary['specIssues']} spec',
              if ((summary['wiringIssues'] ?? 0) > 0)
                '${summary['wiringIssues']} wiring',
              if ((summary['a11yFails'] ?? 0) > 0)
                '${summary['a11yFails']} a11y fail',
              if ((summary['a11yWarns'] ?? 0) > 0)
                '${summary['a11yWarns']} a11y warn',
              if ((summary['invalidAssets'] ?? 0) > 0)
                '${summary['invalidAssets']} invalid assets',
              if ((summary['undefinedState'] ?? 0) > 0)
                '${summary['undefinedState']} undefined state',
              if ((summary['unusedState'] ?? 0) > 0)
                '${summary['unusedState']} unused state',
              if ((summary['deadTokens'] ?? 0) > 0)
                '${summary['deadTokens']} dead tokens',
            ].join(' · ');
    final letter =
        s != null && summary.isNotEmpty ? _letterFromSummary(summary) : null;
    final letterColor =
        letter == null
            ? null
            : (letter == 'A' || letter == 'B'
                ? c.mint
                : letter == 'C'
                ? const Color(0xFFE8B86A)
                : c.coral);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VibeTokens.space3,
        0,
        VibeTokens.space3,
        VibeTokens.space2,
      ),
      child: Tooltip(
        message:
            detail.isEmpty
                ? (status == 'pass' ? 'All green ✓' : 'Health refreshing…')
                : detail,
        waitDuration: const Duration(milliseconds: 200),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space2,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: pillColor,
            borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 12, color: borderColor),
              const SizedBox(width: 6),
              Text(
                'Health · $label',
                style: vibeMono(size: 10, color: c.textSecondary),
              ),
              if (letter != null) ...<Widget>[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: c.surface3,
                    borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                    border: Border.all(color: letterColor!),
                  ),
                  child: Text(
                    letter,
                    style: vibeMono(size: 10, color: letterColor),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Action chips that surface auto-fix opportunities derived from
/// the current health snapshot. Each chip dispatches a single
/// repair tool through `onAction` — no LLM round-trip. Chips
/// disappear when the underlying count drops to 0.
class _QuickFixBar extends StatefulWidget {
  const _QuickFixBar({required this.snapshot, this.onAction});
  final Map<String, dynamic>? snapshot;
  final Future<void> Function(String actionId)? onAction;

  @override
  State<_QuickFixBar> createState() => _QuickFixBarState();
}

class _QuickFixBarState extends State<_QuickFixBar> {
  String? _busy;

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    if (s == null) return const SizedBox.shrink();
    final summary = s['summary'];
    if (summary is! Map) return const SizedBox.shrink();
    final details = s['details'];
    final findings =
        (details is Map ? details['a11y'] : null) is Map
            ? ((details!['a11y'] as Map)['findings'] as List? ??
                const <dynamic>[])
            : const <dynamic>[];
    int fixable = 0;
    for (final f in findings) {
      if (f is! Map) continue;
      final rule = f['rule'];
      if (rule == 'text.minFontSize' || rule == 'touchTarget.minSize') {
        fixable++;
      }
    }
    final invalidAssets = (summary['invalidAssets'] ?? 0) as int;
    final blocking =
        ((summary['specIssues'] ?? 0) as int) +
        ((summary['wiringIssues'] ?? 0) as int) +
        ((summary['a11yFails'] ?? 0) as int) +
        ((summary['invalidAssets'] ?? 0) as int) +
        ((summary['undefinedState'] ?? 0) as int);
    final chips = <Widget>[];
    if (fixable > 0) {
      chips.add(
        _buildChip(
          actionId: 'a11y_quick_fix',
          label: 'Fix $fixable a11y',
          icon: Icons.healing,
          accent: const Color(0xFFE8B86A),
        ),
      );
    }
    if (invalidAssets > 0) {
      chips.add(
        _buildChip(
          actionId: 'asset_audit_apply',
          label:
              'Migrate $invalidAssets asset'
              '${invalidAssets == 1 ? '' : 's'}',
          icon: Icons.auto_fix_high,
          accent: const Color(0xFFE8B86A),
        ),
      );
    }
    // Release chip — present whenever there's work to do (blocking
    // > 0 OR fixable > 0). Multi-stage: runs every auto-repair vibe
    // knows about + final verdict.
    if (blocking > 0 || fixable > 0) {
      chips.add(
        _buildChip(
          actionId: 'release_check',
          label: 'Release check',
          icon: Icons.rocket_launch_outlined,
          accent: VibeTokens.color.mint,
        ),
      );
    }
    if (chips.isEmpty || widget.onAction == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VibeTokens.space3,
        0,
        VibeTokens.space3,
        VibeTokens.space2,
      ),
      child: Wrap(spacing: 6, runSpacing: 6, children: chips),
    );
  }

  Widget _buildChip({
    required String actionId,
    required String label,
    required IconData icon,
    required Color accent,
  }) {
    final c = VibeTokens.colorOf(context);
    final running = _busy == actionId;
    return InkWell(
      onTap:
          running
              ? null
              : () async {
                setState(() => _busy = actionId);
                try {
                  await widget.onAction?.call(actionId);
                } finally {
                  if (mounted) setState(() => _busy = null);
                }
              },
      borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: VibeTokens.space2,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
          border: Border.all(color: accent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (running)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: accent,
                ),
              )
            else
              Icon(icon, size: 12, color: accent),
            const SizedBox(width: 6),
            Text(label, style: vibeMono(size: 10, color: c.textSecondary)),
          ],
        ),
      ),
    );
  }
}

/// Owns the feed's ScrollController + stick-to-bottom heuristic so
/// new turns auto-scroll into view, but a manual scroll-up freezes
/// the view at whatever the user is reading. Same UX pattern as the
/// inspector's wire log.
class _Feed extends StatefulWidget {
  const _Feed({
    required this.turns,
    required this.busy,
    required this.onDeleteTurn,
    required this.layerColorBuilder,
    required this.layerLabelBuilder,
  });
  final List<ChatTurn> turns;
  final bool busy;
  final ValueChanged<ChatTurn> onDeleteTurn;
  final Color Function(Object? layer) layerColorBuilder;
  final String? Function(Object layer) layerLabelBuilder;

  @override
  State<_Feed> createState() => _FeedState();
}

class _FeedState extends State<_Feed> {
  final ScrollController _scroll = ScrollController();
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // 16-px slack — counts as "at bottom" within that range.
    final atBottom =
        (_scroll.position.maxScrollExtent - _scroll.position.pixels) <= 16;
    if (atBottom != _stickToBottom) {
      _stickToBottom = atBottom;
    }
  }

  @override
  void didUpdateWidget(covariant _Feed old) {
    super.didUpdateWidget(old);
    if (!_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.turns.isEmpty && !widget.busy) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(VibeTokens.space4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.chat_bubble_outline,
                size: 32,
                color: VibeTokens.colorOf(context).textMuted,
              ),
              const SizedBox(height: VibeTokens.space2),
              Text(
                'No patches yet. Tell vibe what to build.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: VibeTokens.colorOf(context).textTertiary,
                ),
              ),
            ],
          ),
        ),
      );
    }
    final itemCount = widget.turns.length + (widget.busy ? 1 : 0);
    return ListView.separated(
      key: const Key('vibe.chat.history'),
      controller: _scroll,
      padding: const EdgeInsets.symmetric(
        horizontal: VibeTokens.space3,
        vertical: VibeTokens.space2,
      ),
      itemCount: itemCount,
      separatorBuilder: (_, __) => const SizedBox(height: VibeTokens.space2),
      itemBuilder: (context, i) {
        if (i >= widget.turns.length) return const _BusyIndicator();
        final t = widget.turns[i];
        return _Turn(
          turn: t,
          onDelete: () => widget.onDeleteTurn(t),
          layerColorBuilder: widget.layerColorBuilder,
          layerLabelBuilder: widget.layerLabelBuilder,
        );
      },
    );
  }
}

/// Three-dot pulsing indicator shown while the controller is awaiting
/// an LLM reply. Doubles as a "still alive" affordance when the
/// model takes a while to respond.
class _BusyIndicator extends StatefulWidget {
  const _BusyIndicator();

  @override
  State<_BusyIndicator> createState() => _BusyIndicatorState();
}

class _BusyIndicatorState extends State<_BusyIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: <Widget>[
          AnimatedBuilder(
            animation: _ctrl,
            builder: (ctx, _) {
              final t = _ctrl.value;
              return Row(
                children: <Widget>[
                  for (var i = 0; i < 3; i++) ...<Widget>[
                    Opacity(
                      opacity: 0.3 + 0.7 * _phase(t, i),
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: c.mint,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    if (i < 2) const SizedBox(width: 4),
                  ],
                ],
              );
            },
          ),
          const SizedBox(width: 10),
          Text(
            'thinking…',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: c.textTertiary,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  /// Smooth dot phase so the three dots pulse at offset times
  /// (0, 1/3, 2/3 of the cycle).
  double _phase(double t, int i) {
    final p = (t - i / 3) % 1.0;
    return p < 0.5 ? p * 2 : (1 - p) * 2;
  }
}

class _Turn extends StatelessWidget {
  const _Turn({
    required this.turn,
    required this.layerColorBuilder,
    required this.layerLabelBuilder,
    this.onDelete,
  });
  final ChatTurn turn;
  final VoidCallback? onDelete;
  final Color Function(Object? layer) layerColorBuilder;
  final String? Function(Object layer) layerLabelBuilder;

  @override
  Widget build(BuildContext context) {
    if (turn.role == 'user') {
      return _PromptBubble(turn: turn, onDelete: onDelete);
    }
    if (turn.role == 'system' || turn.role == 'error') {
      return _SystemNote(turn: turn, onDelete: onDelete);
    }
    return _PatchCard(
      turn: turn,
      onDelete: onDelete,
      layerColorBuilder: layerColorBuilder,
      layerLabelBuilder: layerLabelBuilder,
    );
  }
}

/// Tiny hover affordance shared by prompt bubbles and patch cards.
/// Surfaces clipboard + delete icons in the corner on hover; the rest
/// of the turn body uses [SelectableText] so the user can also drag-
/// select. Both actions are optional — pass null to hide either icon.
class _CopyOnHover extends StatefulWidget {
  const _CopyOnHover({required this.text, required this.child, this.onDelete});
  final String text;
  final Widget child;
  final VoidCallback? onDelete;

  @override
  State<_CopyOnHover> createState() => _CopyOnHoverState();
}

class _CopyOnHoverState extends State<_CopyOnHover> {
  bool _hover = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied', style: TextStyle(fontSize: 12)),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required VoidCallback onTap,
    Color? color,
  }) {
    final c = VibeTokens.colorOf(context);
    return Material(
      color: c.surface3,
      borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 12, color: color ?? c.textSecondary),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        children: <Widget>[
          widget.child,
          if (_hover)
            Positioned(
              top: 2,
              right: 2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _iconButton(icon: Icons.copy, onTap: _copy),
                  if (widget.onDelete != null) ...<Widget>[
                    const SizedBox(width: 2),
                    _iconButton(
                      icon: Icons.close,
                      color: c.coral,
                      onTap: widget.onDelete!,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PromptBubble extends StatelessWidget {
  const _PromptBubble({required this.turn, this.onDelete});
  final ChatTurn turn;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Align(
      alignment: Alignment.centerRight,
      child: _CopyOnHover(
        text: turn.text,
        onDelete: onDelete,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.fromLTRB(10, 8, 26, 8),
          decoration: BoxDecoration(
            color: c.surface3,
            borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          ),
          child: SelectableText(
            turn.text,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ),
    );
  }
}

class _PatchCard extends StatelessWidget {
  const _PatchCard({
    required this.turn,
    required this.layerColorBuilder,
    required this.layerLabelBuilder,
    this.onDelete,
  });
  final ChatTurn turn;
  final VoidCallback? onDelete;

  /// Maps `turn.layer` (Object?) to the stripe colour drawn on the
  /// patch card's left edge. Hosts implement based on their domain
  /// layer enum (vibe = LayerId, knowledge tool may use a different
  /// enum). Null layer / unknown values may return any accent.
  final Color Function(Object? layer) layerColorBuilder;

  /// Maps `turn.layer` (non-null) to a short label ("App", "Theme",
  /// ...). Returning null suppresses the prefix and the card just
  /// reads "patched".
  final String? Function(Object layer) layerLabelBuilder;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final layerColor = layerColorBuilder(turn.layer);
    final layerLabel =
        turn.layer == null ? null : layerLabelBuilder(turn.layer!);
    return _CopyOnHover(
      text: turn.text,
      onDelete: onDelete,
      child: Container(
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(VibeTokens.radiusLg),
          border: Border.all(color: c.borderDefault),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(width: 3, color: layerColor),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    VibeTokens.space3,
                    VibeTokens.space3,
                    VibeTokens.space3 + 18,
                    VibeTokens.space3,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Text(
                            layerLabel == null
                                ? 'patched'
                                : '$layerLabel · patched',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: c.textSecondary),
                          ),
                          const Spacer(),
                          if (turn.fileCount != null)
                            Text(
                              '${turn.fileCount} file${turn.fileCount! == 1 ? '' : 's'}',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: c.textTertiary),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      MarkdownBody(
                        data: turn.text,
                        selectable: true,
                        styleSheet: _chatMarkdownStyle(context),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared markdown style — tracks `Theme.bodyMedium` + vbu palette so
/// the rendered output sits visually next to the surrounding chat
/// surface (lists / headings / inline code / fenced code blocks).
MarkdownStyleSheet _chatMarkdownStyle(BuildContext context) {
  final c = VibeTokens.colorOf(context);
  final base =
      Theme.of(context).textTheme.bodyMedium ?? const TextStyle(fontSize: 13);
  final mono = vibeMono(size: 12, color: c.textPrimary);
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: base,
    h1: base.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
    h2: base.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
    h3: base.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
    h4: base.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
    code: mono.copyWith(backgroundColor: c.surface3),
    codeblockPadding: const EdgeInsets.all(8),
    codeblockDecoration: BoxDecoration(
      color: c.surface3,
      borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
    ),
    blockquoteDecoration: BoxDecoration(
      color: c.surface2,
      border: Border(left: BorderSide(color: c.borderStrong, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
    listBullet: base.copyWith(color: c.textSecondary),
    a: base.copyWith(color: c.mint, decoration: TextDecoration.underline),
    tableBorder: TableBorder.all(color: c.borderDefault, width: 1),
    tableHead: base.copyWith(fontWeight: FontWeight.w600),
  );
}

class _SystemNote extends StatelessWidget {
  const _SystemNote({required this.turn, this.onDelete});
  final ChatTurn turn;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final isError = turn.role == 'error';
    return _CopyOnHover(
      text: turn.text,
      onDelete: onDelete,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          0,
          VibeTokens.space1,
          24,
          VibeTokens.space1,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (isError) ...<Widget>[
              Icon(
                Icons.error_outline,
                size: 12,
                color: VibeTokens.status.error,
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: SelectableText(
                turn.text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: VibeTokens.colorOf(context).textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.busy,
    required this.onSubmit,
    this.history = const <String>[],
    this.slashHints,
    this.onDirectDispatch,
  });

  final TextEditingController controller;
  final bool busy;
  final ValueChanged<String> onSubmit;

  /// Submitted user prompts in chronological order — drives the
  /// UpArrow / DownArrow recall in the composer. Most recent at the
  /// tail. Empty list disables history navigation.
  final List<String> history;

  /// Override the chip catalog. Null → fall back to the legacy
  /// default list.
  final List<ChatSlashHint>? slashHints;

  /// Direct-dispatch handler — invoked when the user taps a slash chip
  /// whose hint declares a `tool` field. Bypasses the LLM: the host
  /// resolves the activated bundle's namespace and calls the tool
  /// directly. Null collapses every chip back to template-insert
  /// behavior (legacy default).
  final Future<void> Function(ChatSlashHint hint)? onDirectDispatch;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    // Desktop expectation: Enter sends, Shift+Enter inserts newline.
    // Multi-line TextField swallows Enter by default — we intercept it
    // here via the FocusNode key handler so the composer behaves like
    // Slack / Discord / iMessage rather than a plain text editor.
    _focus = FocusNode(onKeyEvent: _onKey);
    // Note — the slash-hint visibility used to live behind a
    // setState mirror of `controller.text`. Removed: the rebuild on
    // every keystroke disrupted Hangul IME composition (first
    // character of a composing block dropped because the column
    // rebuild reshuffled the TextField's IME connection). The hint
    // strip now reads the controller directly via
    // ValueListenableBuilder, scoping rebuilds to the hint Wrap and
    // leaving the TextField subtree untouched.
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// Cursor into [widget.history]. -1 means "live edit, no recall."
  /// 0..N-1 maps to history entries (0 = oldest, history.length-1 =
  /// most recent). Bumped by UpArrow / DownArrow when the input is
  /// empty or a recalled value untouched.
  int _historyCursor = -1;
  String? _liveDraftBeforeRecall;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // Tab: complete a unique slash prefix.
    if (key == LogicalKeyboardKey.tab) {
      final t = widget.controller.text;
      if (t.startsWith('/') && t.split(RegExp(r'\s')).length == 1) {
        final prefix = t.substring(1).toLowerCase();
        final matches =
            (widget.slashHints ?? _kDefaultSlashHints)
                .where(
                  (h) =>
                      h.command.substring(1).toLowerCase().startsWith(prefix),
                )
                .toList();
        if (matches.length == 1) {
          final m = matches.first;
          widget.controller.text = m.command + (m.template ?? '');
          widget.controller.selection = TextSelection.collapsed(
            offset: widget.controller.text.length,
          );
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }
    // UpArrow: recall older history entry. Only when caret is at
    // start (no text below the cursor) so multi-line drafts keep
    // arrow-key navigation inside the field.
    if (key == LogicalKeyboardKey.arrowUp) {
      if (widget.history.isEmpty) return KeyEventResult.ignored;
      final caret = widget.controller.selection.baseOffset;
      if (caret < 0) return KeyEventResult.ignored;
      final pre = widget.controller.text.substring(0, caret);
      if (pre.contains('\n')) return KeyEventResult.ignored;
      // Stash the live draft on first recall so DownArrow can
      // restore it cleanly.
      if (_historyCursor == -1) {
        _liveDraftBeforeRecall = widget.controller.text;
        _historyCursor = widget.history.length - 1;
      } else if (_historyCursor > 0) {
        _historyCursor--;
      } else {
        return KeyEventResult.handled;
      }
      widget.controller.text = widget.history[_historyCursor];
      widget.controller.selection = TextSelection.collapsed(
        offset: widget.controller.text.length,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_historyCursor == -1) return KeyEventResult.ignored;
      final caret = widget.controller.selection.baseOffset;
      final post = caret < 0 ? '' : widget.controller.text.substring(caret);
      if (post.contains('\n')) return KeyEventResult.ignored;
      if (_historyCursor < widget.history.length - 1) {
        _historyCursor++;
        widget.controller.text = widget.history[_historyCursor];
      } else {
        // Past the most recent — drop back to live draft.
        _historyCursor = -1;
        widget.controller.text = _liveDraftBeforeRecall ?? '';
        _liveDraftBeforeRecall = null;
      }
      widget.controller.selection = TextSelection.collapsed(
        offset: widget.controller.text.length,
      );
      return KeyEventResult.handled;
    }
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (shift) return KeyEventResult.ignored; // let TextField insert \n
    if (widget.busy) return KeyEventResult.handled; // swallow during send
    widget.onSubmit(widget.controller.text);
    // Reset history cursor on submit so the next UpArrow walks from
    // the new most-recent entry.
    _historyCursor = -1;
    _liveDraftBeforeRecall = null;
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Hint strip rebuilds in isolation as the controller text
        // changes — the TextField subtree below stays mounted, which
        // is what the IME composition state is anchored to.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) {
            final draftTrim = value.text.trim();
            final isSlash = draftTrim.startsWith('/');
            final showHints = draftTrim.isEmpty || isSlash;
            if (!showHints) return const SizedBox.shrink();
            final filter = isSlash ? draftTrim.substring(1).toLowerCase() : '';
            return Padding(
              padding: const EdgeInsets.fromLTRB(
                VibeTokens.space3,
                0,
                VibeTokens.space3,
                VibeTokens.space1,
              ),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: <Widget>[
                  for (final hint in (widget.slashHints ?? _kDefaultSlashHints))
                    if (filter.isEmpty || hint.command.contains(filter))
                      Tooltip(
                        message:
                            hint.isDirectDispatch
                                ? '${hint.command}\ntool: ${hint.tool}\n(direct dispatch — bypasses LLM)'
                                : hint.command,
                        waitDuration: const Duration(milliseconds: 250),
                        child: InkWell(
                          onTap: () {
                            if (hint.isDirectDispatch &&
                                widget.onDirectDispatch != null) {
                              // ignore: unawaited_futures
                              widget.onDirectDispatch!(hint);
                              return;
                            }
                            widget.controller.text =
                                hint.command + (hint.template ?? '');
                            widget
                                .controller
                                .selection = TextSelection.collapsed(
                              offset: widget.controller.text.length,
                            );
                            _focus.requestFocus();
                          },
                          borderRadius: BorderRadius.circular(
                            VibeTokens.radiusSm,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  hint.isDirectDispatch
                                      ? c.surface2
                                      : c.surface3,
                              borderRadius: BorderRadius.circular(
                                VibeTokens.radiusSm,
                              ),
                              border: Border.all(
                                color:
                                    hint.isDirectDispatch
                                        ? c.mintDim
                                        : c.borderDefault,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                if (hint.isDirectDispatch) ...<Widget>[
                                  Icon(Icons.bolt, size: 11, color: c.mintDim),
                                  const SizedBox(width: 2),
                                ],
                                Text(
                                  hint.command,
                                  style: vibeMono(
                                    size: 10,
                                    color: c.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            VibeTokens.space3,
            VibeTokens.space2,
            VibeTokens.space3,
            VibeTokens.space3,
          ),
          child: TextField(
            key: const Key('vibe.chat.input'),
            controller: widget.controller,
            focusNode: _focus,
            minLines: 1,
            maxLines: 6,
            textInputAction: TextInputAction.newline,
            onSubmitted: widget.busy ? null : (text) => widget.onSubmit(text),
            decoration: InputDecoration(
              hintText:
                  'Describe a change… (Shift+Enter for newline · / for commands)',
              suffixIcon: IconButton(
                icon: Icon(
                  Icons.send,
                  size: 16,
                  color: VibeTokens.colorOf(context).mint,
                ),
                onPressed:
                    widget.busy
                        ? null
                        : () => widget.onSubmit(widget.controller.text),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Fallback slash command catalog used when `ChatPanel.slashHints` is
/// null. Matches the original vibe_app_builder set so the standalone
/// builder keeps its composer chips with no migration work.
const List<ChatSlashHint> _kDefaultSlashHints = <ChatSlashHint>[
  ChatSlashHint('/health'),
  ChatSlashHint('/grade'),
  ChatSlashHint('/release'),
  ChatSlashHint('/audit'),
  ChatSlashHint('/routes'),
  ChatSlashHint('/find ', ''),
  ChatSlashHint('/graph'),
  ChatSlashHint('/tokens'),
  ChatSlashHint('/desc ', ''),
  ChatSlashHint('/lint'),
  ChatSlashHint('/extract ', ''),
  ChatSlashHint('/fix'),
  ChatSlashHint('/preset ', ''),
  ChatSlashHint('/recipe ', ''),
  ChatSlashHint('/help'),
];
