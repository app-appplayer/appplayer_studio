import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:appplayer_studio/base.dart' show ChromeBridge;
import 'package:appplayer_studio/ui.dart';

/// Branding — read `<scene_builder.mbd>/branding/theme.json` and render
/// the color palette + font tokens. First cut is read-only; the next
/// round wires per-token edit + save through `studio.builder.writeBundleFile`.
class BrandingView extends StatefulWidget {
  const BrandingView({
    super.key,
    required this.bundlePath,
    required this.chromeBridge,
  });

  final String bundlePath;
  final ChromeBridge chromeBridge;

  @override
  State<BrandingView> createState() => _BrandingViewState();
}

class _BrandingViewState extends State<BrandingView> {
  Map<String, dynamic>? _theme;
  bool _loading = true;
  String? _error;
  String? _sourcePath;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(
    String tool,
    Map<String, dynamic> params,
  ) async {
    final fn = widget.chromeBridge.callHostTool;
    if (fn == null) {
      return <String, dynamic>{'ok': false, 'error': 'chrome bridge not wired'};
    }
    return fn(tool, params);
  }

  Map<String, dynamic>? _unwrap(Map<String, dynamic> result) {
    final content = result['content'];
    if (content is List && content.isNotEmpty) {
      final first = content.first;
      if (first is Map && first['text'] is String) {
        try {
          final decoded = jsonDecode(first['text'] as String);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {
          /* fall through */
        }
      }
    }
    return null;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // Resolve the scene_builder seed mbd path via the bundle registry.
    final listResult = await _call(
      'studio.bundle.list',
      const <String, dynamic>{},
    );
    if (!mounted) return;
    final listBody = _unwrap(listResult) ?? listResult;
    final bundles = listBody['bundles'];
    String? mbdPath;
    if (bundles is List) {
      // Prefer entries that have manifest meta loaded (`name` set) so
      // stale registry entries from earlier builds (no mbd on disk) are
      // skipped automatically.
      for (final b in bundles) {
        if (b is Map &&
            b['namespace'] == 'scene_builder' &&
            b['name'] != null) {
          mbdPath = b['mbdPath']?.toString();
          break;
        }
      }
      // Fallback: any entry with matching namespace.
      if (mbdPath == null) {
        for (final b in bundles) {
          if (b is Map && b['namespace'] == 'scene_builder') {
            mbdPath = b['mbdPath']?.toString();
            break;
          }
        }
      }
    }
    if (mbdPath == null) {
      setState(() {
        _loading = false;
        _error = 'scene_builder bundle not registered';
      });
      return;
    }
    final readResult = await _call('studio.bundle.read_file', <String, dynamic>{
      'mbdPath': mbdPath,
      'relPath': 'branding/theme.json',
    });
    if (!mounted) return;
    final readBody = _unwrap(readResult) ?? readResult;
    if (readBody['ok'] == false) {
      setState(() {
        _loading = false;
        _error = readBody['error']?.toString() ?? 'failed';
      });
      return;
    }
    final content = readBody['content']?.toString();
    if (content == null) {
      setState(() {
        _loading = false;
        _error = 'theme.json empty';
      });
      return;
    }
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        setState(() {
          _loading = false;
          _theme = decoded;
          _sourcePath = '$mbdPath/branding/theme.json';
        });
        return;
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'parse: $e';
      });
      return;
    }
    setState(() {
      _loading = false;
      _error = 'theme.json is not a JSON object';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    if (_loading) {
      return Center(
        child: Text(
          'Loading…',
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.textTertiary,
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Text(
          'Failed: $_error',
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.coral,
          ),
        ),
      );
    }
    final theme = _theme!;
    return ListView(
      padding: const EdgeInsets.all(VbuTokens.space3),
      children: <Widget>[
        _header(theme),
        const SizedBox(height: VbuTokens.space4),
        _colorsSection(theme['colors']),
        const SizedBox(height: VbuTokens.space4),
        _fontsSection(theme['fonts']),
        const SizedBox(height: VbuTokens.space4),
        _logoSection(theme['logo']),
      ],
    );
  }

  Widget _header(Map<String, dynamic> theme) {
    final c = VbuTokens.colorOf(context);
    final name = theme['name']?.toString() ?? 'Unnamed theme';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          name,
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: c.textPrimary,
          ),
        ),
        if (_sourcePath != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            _sourcePath!,
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 10,
              color: c.textMuted,
            ),
          ),
        ],
      ],
    );
  }

  Widget _colorsSection(Object? colors) {
    final c = VbuTokens.colorOf(context);
    if (colors is! Map) {
      return _sectionLabel('Colors', c, hint: '(none)');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _sectionLabel('Colors', c),
        const SizedBox(height: VbuTokens.space2),
        Wrap(
          spacing: VbuTokens.space2,
          runSpacing: VbuTokens.space2,
          children: <Widget>[
            for (final entry in colors.entries)
              _swatch(entry.key.toString(), entry.value?.toString() ?? ''),
          ],
        ),
      ],
    );
  }

  Widget _swatch(String key, String hex) {
    final c = VbuTokens.colorOf(context);
    final color = _parseHex(hex);
    return Container(
      width: 168,
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.borderDefault, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: 56,
            decoration: BoxDecoration(
              color: color ?? c.surface3,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(5),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  key,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: c.textPrimary,
                  ),
                ),
                Text(
                  hex,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 10,
                    color: c.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color? _parseHex(String hex) {
    var v = hex.trim();
    if (v.startsWith('#')) v = v.substring(1);
    if (v.length == 6) v = 'FF$v';
    final n = int.tryParse(v, radix: 16);
    return n == null ? null : Color(n);
  }

  Widget _fontsSection(Object? fonts) {
    final c = VbuTokens.colorOf(context);
    if (fonts is! Map) {
      return _sectionLabel('Fonts', c, hint: '(none)');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _sectionLabel('Fonts', c),
        const SizedBox(height: VbuTokens.space2),
        for (final entry in fonts.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 60,
                  child: Text(
                    entry.key.toString(),
                    style: TextStyle(
                      fontFamily: VbuTokens.fontMono,
                      fontSize: 11,
                      color: c.textSecondary,
                    ),
                  ),
                ),
                Text(
                  entry.value?.toString() ?? '',
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: c.textPrimary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _logoSection(Object? logo) {
    final c = VbuTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _sectionLabel('Logo', c),
        const SizedBox(height: VbuTokens.space2),
        Text(
          logo?.toString() ?? '(none)',
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.textTertiary,
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(String label, dynamic c, {String? hint}) {
    return Row(
      children: <Widget>[
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.0,
            color: c.textTertiary,
          ),
        ),
        if (hint != null) ...<Widget>[
          const SizedBox(width: 6),
          Text(
            hint,
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 10,
              color: c.textMuted,
            ),
          ),
        ],
      ],
    );
  }
}
