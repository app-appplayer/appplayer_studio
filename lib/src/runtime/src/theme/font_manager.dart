/// Font manager for MCP UI DSL v1.1
///
/// Manages custom font loading, availability tracking, and fallback chain
/// resolution. Works alongside ThemeManager to provide font management
/// for the runtime.
library font_manager;

import '../utils/mcp_logger.dart';

/// Loading state of a font family
enum FontState {
  /// Font is currently being loaded
  loading,

  /// Font has been loaded successfully
  loaded,

  /// Font failed to load
  error,

  /// Font is not registered or known
  notFound,
}

/// Configuration for loading a custom font
class FontConfig {
  /// The font family name as referenced in typography definitions
  final String family;

  /// Optional URL or asset path to load the font from
  final String? source;

  /// Optional font weight (e.g., 400, 700)
  final int? weight;

  /// Optional font style ('normal', 'italic')
  final String? style;

  const FontConfig({
    required this.family,
    this.source,
    this.weight,
    this.style,
  });

  /// Create from JSON definition
  factory FontConfig.fromJson(Map<String, dynamic> json) {
    return FontConfig(
      family: json['family'] as String,
      source: json['source'] as String?,
      weight: json['weight'] as int?,
      style: json['style'] as String?,
    );
  }

  /// Serialize to JSON
  Map<String, dynamic> toJson() => {
        'family': family,
        if (source != null) 'source': source,
        if (weight != null) 'weight': weight,
        if (style != null) 'style': style,
      };
}

/// Manages font loading, state tracking, and fallback resolution
///
/// Tracks the loading state of custom fonts and provides fallback chain
/// resolution for typography definitions. System fonts are always considered
/// available.
class FontManager {
  final MCPLogger _logger = MCPLogger('FontManager');

  /// Current state of each registered font family
  final Map<String, FontState> _fontStates = {};

  /// Set of system fonts that are always available
  static const Set<String> _systemFonts = {
    'Roboto',
    'Arial',
    'Helvetica',
    'Times New Roman',
    'Courier New',
    'Georgia',
    'Verdana',
    'sans-serif',
    'serif',
    'monospace',
  };

  /// Load a list of font configurations asynchronously
  ///
  /// Each font transitions through loading -> loaded/error states.
  /// Fonts that are already loaded or currently loading are skipped.
  Future<void> loadFonts(List<FontConfig> fonts) async {
    for (final font in fonts) {
      final family = font.family;

      // Skip if already loaded or currently loading
      if (_fontStates[family] == FontState.loaded ||
          _fontStates[family] == FontState.loading) {
        continue;
      }

      _fontStates[family] = FontState.loading;
      _logger.debug('Loading font: $family');

      try {
        // Attempt to load the font. In the current implementation, fonts
        // are expected to be bundled as Flutter assets. Network font loading
        // (e.g., via client:// protocol) is planned for a future release.
        await _loadFont(font);
        _fontStates[family] = FontState.loaded;
        _logger.debug('Font loaded: $family');
      } catch (e) {
        _fontStates[family] = FontState.error;
        _logger.error('Failed to load font "$family": $e');
      }
    }
  }

  /// Get the current loading state of a font family
  ///
  /// Returns [FontState.notFound] if the font has not been registered
  /// or loaded. System fonts always return [FontState.loaded].
  FontState getFontState(String fontFamily) {
    if (_systemFonts.contains(fontFamily)) {
      return FontState.loaded;
    }
    return _fontStates[fontFamily] ?? FontState.notFound;
  }

  /// Check if a font family is available for use
  ///
  /// Returns true if the font is a known system font or has been
  /// successfully loaded.
  bool isFontAvailable(String fontFamily) {
    return getFontState(fontFamily) == FontState.loaded;
  }

  /// Resolve a fallback chain by returning the first available font
  ///
  /// Iterates through the provided font family names and returns the
  /// first one that is available (loaded or system font). Returns null
  /// if no font in the chain is available.
  String? resolveFallbackChain(List<String> fonts) {
    for (final font in fonts) {
      if (isFontAvailable(font)) {
        return font;
      }
    }
    _logger.debug(
      'No available font in fallback chain: ${fonts.join(", ")}',
    );
    return null;
  }

  /// Mark a font as loaded (for testing or pre-bundled fonts)
  void markLoaded(String fontFamily) {
    _fontStates[fontFamily] = FontState.loaded;
  }

  /// Mark a font as errored (for testing)
  void markError(String fontFamily) {
    _fontStates[fontFamily] = FontState.error;
  }

  /// Clear all font states (for testing or reset)
  void clear() {
    _fontStates.clear();
  }

  /// Internal font loading implementation
  ///
  /// Currently a no-op that marks fonts as loaded. Actual network
  /// font loading will be implemented when client:// protocol
  /// support is added.
  Future<void> _loadFont(FontConfig font) async {
    // Simulate async font loading. In a real implementation, this would
    // use FontLoader or similar to load font bytes from a URL/asset.
    // For now, bundled fonts are assumed available.
    if (font.source == null) {
      // No source specified - assume the font is bundled in the app
      return;
    }

    // Future: load font bytes from font.source via FontLoader
    // For now, fonts with a source are marked as loaded optimistically
  }
}
