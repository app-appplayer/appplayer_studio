/// Welcome panel — shown when the studio host has no project open.
/// Centred New / Open buttons + a Recent Projects list (only when the
/// host actually passes recents).
///
/// Public surface: pass [recents], [onNew], [onOpen], [onPickRecent]
/// from the host. Title text defaults to "AppPlayer Builder" but can
/// be overridden per host (vibe_app_builder, knowledge_builder, ...).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:appplayer_studio/ui.dart';

class StudioWelcomePanel extends StatelessWidget {
  const StudioWelcomePanel({
    super.key,
    required this.recents,
    required this.onNew,
    required this.onOpen,
    required this.onPickRecent,
    this.title = 'AppPlayer Builder',
    this.subtitle =
        'No project open. Create a new one or open an existing project to start.',
  });

  final List<String> recents;
  final VoidCallback onNew;
  final VoidCallback onOpen;
  final ValueChanged<String> onPickRecent;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return VbuHeroPanel(
      title: title,
      subtitle: subtitle,
      actions: <VbuHeroAction>[
        VbuHeroAction(
          label: 'New Project',
          icon: Icons.add_circle_outlined,
          onPressed: onNew,
          emphasised: true,
        ),
        VbuHeroAction(
          label: 'Open Project',
          icon: Icons.folder_open_outlined,
          onPressed: onOpen,
        ),
      ],
      footer:
          recents.isEmpty
              ? null
              : _RecentList(recents: recents, onPickRecent: onPickRecent),
    );
  }
}

class _RecentList extends StatelessWidget {
  const _RecentList({required this.recents, required this.onPickRecent});

  final List<String> recents;
  final ValueChanged<String> onPickRecent;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: VbuTokens.space2),
        Padding(
          padding: const EdgeInsets.only(left: VbuTokens.space2),
          child: Text(
            'RECENT PROJECTS',
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: c.textTertiary,
            ),
          ),
        ),
        const SizedBox(height: VbuTokens.space2),
        Container(
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
            border: Border.all(color: c.borderDefault),
          ),
          child: Column(
            children: <Widget>[
              for (var i = 0; i < recents.length; i++) ...<Widget>[
                if (i > 0)
                  Divider(height: 1, thickness: 1, color: c.borderDefault),
                _RecentRow(
                  path: recents[i],
                  onTap: () => onPickRecent(recents[i]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _RecentRow extends StatefulWidget {
  const _RecentRow({required this.path, required this.onTap});

  final String path;
  final VoidCallback onTap;

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final base = widget.path.split(Platform.pathSeparator).last;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: VbuTokens.durFast,
          curve: VbuTokens.easeStandard,
          color: _hovered ? c.surface3 : Colors.transparent,
          padding: const EdgeInsets.symmetric(
            horizontal: VbuTokens.space3,
            vertical: VbuTokens.space2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                base,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: c.textPrimary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.path,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 11,
                  color: c.textTertiary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
