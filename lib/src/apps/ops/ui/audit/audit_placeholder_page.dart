import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/ops_atoms.dart';

/// Generic screen placeholder used for the Action / Audit slot until the
/// mcp_browser live view + audit trail design lands. Header chrome stays
/// consistent with hi-fi screens; the body is a centered hint.
class AuditPlaceholderPage extends StatelessWidget {
  const AuditPlaceholderPage({
    super.key,
    this.crumb = 'System',
    this.title = 'Action / Audit',
    this.hint = 'mcp_browser live view + audit trail — coming next iteration',
  });

  final String crumb;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OpsCrumb(crumb),
            const SizedBox(height: 4),
            Text(title, style: Theme.of(context).textTheme.displayMedium),
            const SizedBox(height: 22),
            OpsCard(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 60),
              body: Center(
                child: Text(
                  hint,
                  style: TextStyle(
                    fontFamily: OpsType.mono,
                    fontSize: 12,
                    color: OpsColors.text3,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
