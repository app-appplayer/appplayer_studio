import 'package:appplayer_studio/builtin_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '_axis_management_page.dart';

/// Profiles management — workspace-level integrated list. Pool seeds +
/// every agent's owned (in-progress) profile fork are visible together so
/// any entry can be inspected, attached to another agent, or used as a
/// transfer source for a new agent.
class ProfilesPage extends ConsumerWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(integratedAxisProvider(AgentAxis.profile));
    return AxisManagementPage(
      axis: AgentAxis.profile,
      title: 'Profiles',
      icon: Icons.face_outlined,
      list: list,
    );
  }
}
