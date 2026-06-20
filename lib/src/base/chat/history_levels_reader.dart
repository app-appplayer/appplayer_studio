/// Build the Studio · Package · Project [HistoryLevel] list every
/// studio host shows in the chat history dialog. Reads the active tab
/// out of the [ChromeBridge.listTabs] snapshot + the active package
/// notifier the host keeps in sync as tabs change.
///
/// Pure top-level helper — base owns the level ordering / labels and
/// chat-file path arithmetic; the host owns the bridge + notifier +
/// configRoot so override hooks (custom labels, extra levels) can be
/// composed by wrapping this function's output.
library;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../main/chrome_bridge.dart';
import 'chat_persistence.dart';
import 'history_dialog.dart';

/// Resolve the chat-history levels for the currently-active tab.
///
/// * `studio` — always present, points at the home chat log.
/// * `package` — added when [activePackagePath] is non-null. Sublabel
///   resolved against the bridge's `listTabs` snapshot.
/// * `project` — added when the active tab carries a `currentProject`
///   entry. Sublabel is the project folder basename.
List<HistoryLevel> resolveStudioHistoryLevels({
  required ChromeBridge bridge,
  required String? activePackagePath,
  required String configRoot,
}) {
  final list = bridge.listTabs?.call() ?? const <Map<String, dynamic>>[];
  String? activePkgName;
  String? activeProjectPath;
  if (activePackagePath != null) {
    final entry = list.firstWhere(
      (e) => e['key'] == activePackagePath,
      orElse: () => <String, dynamic>{},
    );
    activePkgName = entry['name'] as String?;
    activeProjectPath = entry['currentProject'] as String?;
  }
  final levels = <HistoryLevel>[
    HistoryLevel(
      id: 'studio',
      label: 'Studio',
      sublabel: 'AppPlayer Studio',
      icon: Icons.tune,
      filePath: studioChatFile(configRoot: configRoot, key: 'home'),
    ),
  ];
  if (activePackagePath != null) {
    levels.add(
      HistoryLevel(
        id: 'package',
        label: 'Package',
        sublabel: activePkgName ?? activePackagePath,
        icon: Icons.extension_outlined,
        filePath: studioChatFile(
          configRoot: configRoot,
          key: activePackagePath,
        ),
      ),
    );
    if (activeProjectPath != null) {
      levels.add(
        HistoryLevel(
          id: 'project',
          label: 'Project',
          sublabel: p.basename(activeProjectPath),
          icon: Icons.folder_outlined,
          filePath: studioChatFile(
            configRoot: configRoot,
            key: '$activePackagePath::$activeProjectPath',
          ),
        ),
      );
    }
  }
  return levels;
}
