/// Welcome panel shown when the universal host has no package
/// installed. Distinct from [StudioWelcomePanel] (which prompts the
/// user to create / open a *project* once a package is active) — this
/// one prompts the user to install the *package* itself, which is the
/// outer step.
///
/// "Package" = a bundle with function (e.g. app_builder, knowledge,
/// demo_studio). Install once, then projects live inside it.
library;

import 'package:flutter/material.dart';
import 'package:appplayer_studio/ui.dart';

class PackageWelcomePanel extends StatelessWidget {
  const PackageWelcomePanel({
    super.key,
    required this.onInstall,
    this.onCreate,
    this.title = 'AppPlayer Studio',
    this.subtitle = 'Install or create a package to begin.',
    this.hint =
        'Install: pick a `.mcpb` archive or `.mbd/` folder, or call '
            '`studio.bundle.install` via MCP. · '
            'Create: scaffold a new empty `.mbd/` and start authoring.',
  });

  /// Invoked when the user taps the Install button. Host typically
  /// opens a native file picker and forwards the chosen path to
  /// [BundleInstallSurface.install].
  final VoidCallback onInstall;

  /// Invoked when the user taps the Create button. Null hides the
  /// Create action (e.g. shells that don't support authoring).
  final VoidCallback? onCreate;

  final String title;
  final String subtitle;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return VbuHeroPanel(
      title: title,
      subtitle: subtitle,
      actions: <VbuHeroAction>[
        VbuHeroAction(
          label: 'Install Package',
          icon: Icons.folder_open_outlined,
          onPressed: onInstall,
          emphasised: true,
        ),
        if (onCreate != null)
          VbuHeroAction(
            label: 'Create Package',
            icon: Icons.add,
            onPressed: onCreate!,
          ),
      ],
      footer: Text(
        hint,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 11,
          color: c.textTertiary,
          height: 1.5,
        ),
      ),
    );
  }
}
