import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ops_atoms.dart';
import 'ops_models.dart';

class OpsActivityRow extends StatelessWidget {
  const OpsActivityRow({
    super.key,
    required this.actor,
    required this.headline,
    required this.meta,
    this.isLast = false,
  });

  final ActivityActor actor;
  final InlineSpan headline;
  final String meta;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border:
            isLast ? null : Border(bottom: BorderSide(color: OpsColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OpsActorAvatar(actor: actor, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  headline,
                  style: const TextStyle(
                    fontFamily: OpsType.sans,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  meta,
                  style: TextStyle(
                    fontFamily: OpsType.mono,
                    fontSize: 10,
                    color: OpsColors.text3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper to build a styled headline with actor name + verb + reference.
TextSpan opsActivityHeadline({
  required String actorName,
  required String verb,
  String? ref,
  String? tag,
  String? trailing,
}) {
  return TextSpan(
    children: [
      TextSpan(
        text: actorName,
        style: const TextStyle(fontWeight: OpsType.semibold),
      ),
      TextSpan(text: ' $verb '),
      if (ref != null)
        TextSpan(
          text: ref,
          style: TextStyle(fontFamily: OpsType.mono, color: OpsColors.accent),
        ),
      if (tag != null)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: OpsColors.surface2,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              tag,
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 10,
                color: OpsColors.text2,
              ),
            ),
          ),
        ),
      if (trailing != null) TextSpan(text: ' $trailing'),
    ],
  );
}
