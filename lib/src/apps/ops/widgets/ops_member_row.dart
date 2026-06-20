import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ops_atoms.dart';
import 'ops_models.dart';

class OpsMemberRow extends StatelessWidget {
  const OpsMemberRow({
    super.key,
    required this.member,
    this.onTap,
    this.isLast = false,
  });

  final MemberSummary member;
  final VoidCallback? onTap;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border:
              isLast
                  ? null
                  : Border(bottom: BorderSide(color: OpsColors.border)),
        ),
        child: Row(
          children: [
            OpsActorAvatar(
              actor: member.actor,
              size: 32,
              online: member.online,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          member.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: OpsType.semibold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OpsRoleTag(kind: member.kind),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    member.subtitle,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: OpsType.mono,
                      fontSize: 10,
                      color: OpsColors.text3,
                    ),
                  ),
                ],
              ),
            ),
            if (member.kind == MemberKind.ai)
              OpsLevelBars(levels: member.layerProgress),
          ],
        ),
      ),
    );
  }
}
