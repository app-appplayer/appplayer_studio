import 'package:appplayer_studio/builtin_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../profile/_axis_management_page.dart';

/// Philosophies management — workspace-level integrated list. Pool seeds +
/// every agent's owned (in-progress) philosophy fork are visible together
/// so any entry can be inspected or attached to another agent.
class PhilosophiesPage extends ConsumerWidget {
  const PhilosophiesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(integratedAxisProvider(AgentAxis.philosophy));
    return AxisManagementPage(
      axis: AgentAxis.philosophy,
      title: 'Philosophies',
      icon: Icons.balance_outlined,
      list: list,
    );
  }
}
