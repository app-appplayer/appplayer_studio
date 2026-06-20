import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/ui.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  test('VbuTokens spacing scale is 4px-based', () {
    expect(VbuTokens.space1, 4);
    expect(VbuTokens.space4, 16);
    expect(VbuTokens.space8, 32);
    expect(VbuTokens.space16, 64);
  });

  test('VbuTokens radius / layout constants intact', () {
    expect(VbuTokens.radiusMd, 6);
    expect(VbuTokens.radiusLg, 10);
    expect(VbuTokens.titlebarHeight, 28);
    expect(VbuTokens.statusbarHeight, 24);
    expect(VbuTokens.sideColumnWidth, 320);
  });

  test('VbuTokens.color surfaces are vibe-derived hexes', () {
    // Surfaces (darkest → lightest)
    expect(VbuTokens.color.bg.toARGB32(), 0xFF0B0E13);
    expect(VbuTokens.color.surface.toARGB32(), 0xFF11151C);
    expect(VbuTokens.color.surface2.toARGB32(), 0xFF161B24);
    expect(VbuTokens.color.surface3.toARGB32(), 0xFF1C2230);
    // Accents
    expect(VbuTokens.color.mint.toARGB32(), 0xFF7DD3C0);
    expect(VbuTokens.color.violet.toARGB32(), 0xFF9B87F5);
    expect(VbuTokens.color.coral.toARGB32(), 0xFFE78A7A);
  });

  test('VbuTokens.status severities tint per badge family', () {
    expect(VbuTokens.status.ok.toARGB32(), 0xFF7DD3C0);
    expect(VbuTokens.status.warn.toARGB32(), 0xFFE9B873);
    expect(VbuTokens.status.error.toARGB32(), 0xFFE78A7A);
  });

  // GoogleFonts pulls Inter/JetBrainsMono lazily over the network.
  // We disable that in setUpAll, but the resulting TextTheme builder
  // still raises in unit tests because no fonts are bundled. Theme
  // smoke tests are intentionally limited to fields that don't go
  // through the GoogleFonts pipeline; full theme rendering is verified
  // through downstream widget tests (vibe / kb / vibe_studio).
  test('Color hexes feed _darkScheme / _lightScheme without going '
      'through GoogleFonts', () {
    final c = VbuTokens.color;
    // Spot-check the static hex constants stay aligned with vibe.
    expect(c.bg.toARGB32(), 0xFF0B0E13);
    expect(c.elevated.toARGB32(), 0xFF1F2633);
    expect(c.borderDefault.toARGB32(), 0xFF232A38);
  });
}
