/// Generic empty-state body for the universal host's per-bundle editor
/// modes. Renders a centred icon + mode label + summary line + the
/// bundle path. Used as a baseline by the Knowledge and Manifest editor
/// modes until they grow proper per-domain surfaces — and as a reusable
/// "no real editor yet" frame for future modes.
import 'package:flutter/material.dart';
import 'package:appplayer_studio/ui.dart';

class BundleEditorPlaceholder extends StatelessWidget {
  const BundleEditorPlaceholder({
    super.key,
    required this.bundlePath,
    required this.mode,
    required this.summary,
  });
  final String bundlePath;
  final String mode;
  final String summary;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(VbuTokens.space5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.architecture_outlined, size: 32, color: c.textTertiary),
            const SizedBox(height: VbuTokens.space2),
            Text(
              '$mode editor — placeholder',
              style: TextStyle(
                fontFamily: VbuTokens.fontSans,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.textSecondary,
              ),
            ),
            const SizedBox(height: VbuTokens.space2),
            Text(
              summary,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: c.textTertiary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: VbuTokens.space3),
            Text(
              bundlePath,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 10,
                color: c.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
