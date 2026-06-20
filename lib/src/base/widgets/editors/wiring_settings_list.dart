/// Renderer for a single "DOMAIN ACTIONS" SettingsSection sourced from
/// `manifest.wiring.settings[]`. Each entry is a tappable row — icon
/// + label + optional category badge — that fires the bound tool with
/// the entry's declared arguments. Failures land via the host's
/// notify slot, mirroring the domain icon dispatch path.
///
/// Lifted from the studio_builder host into base so every studio host
/// renders wiring-declared action entries the same way.
library;

import 'package:flutter/material.dart';

class WiringSettingsList extends StatelessWidget {
  const WiringSettingsList({
    super.key,
    required this.entries,
    required this.onFire,
  });

  final List<Map<String, dynamic>> entries;
  final Future<void> Function(String toolShort, Map<String, dynamic> args)
  onFire;

  IconData _materialIcon(String name) {
    // Lightweight map — same lookup style as host's domain icons but
    // skewed toward settings-style verbs. Unknown names fall back to
    // tune so the row still renders.
    switch (name) {
      case 'tune':
        return Icons.tune;
      case 'refresh':
        return Icons.refresh;
      case 'delete':
        return Icons.delete_outline;
      case 'clear':
        return Icons.clear_all;
      case 'export':
        return Icons.file_upload;
      case 'import':
        return Icons.file_download;
      case 'reset':
        return Icons.restart_alt;
      case 'save':
        return Icons.save_outlined;
      case 'sync':
        return Icons.sync;
      case 'cloud':
        return Icons.cloud_outlined;
      case 'database':
        return Icons.storage_outlined;
      case 'lock':
        return Icons.lock_outline;
      case 'unlock':
        return Icons.lock_open_outlined;
      case 'key':
        return Icons.vpn_key_outlined;
      case 'shield':
        return Icons.shield_outlined;
      default:
        return Icons.tune;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final e in entries)
          WiringSettingsRow(
            label: e['label']!.toString(),
            iconData: _materialIcon(e['icon']?.toString() ?? 'tune'),
            category: e['category']?.toString(),
            onTap: () {
              final args = e['arguments'];
              onFire(
                e['tool']!.toString(),
                args is Map
                    ? Map<String, dynamic>.from(args)
                    : const <String, dynamic>{},
              );
            },
          ),
      ],
    );
  }
}

class WiringSettingsRow extends StatefulWidget {
  const WiringSettingsRow({
    super.key,
    required this.label,
    required this.iconData,
    required this.category,
    required this.onTap,
  });

  final String label;
  final IconData iconData;
  final String? category;
  final VoidCallback onTap;

  @override
  State<WiringSettingsRow> createState() => _WiringSettingsRowState();
}

class _WiringSettingsRowState extends State<WiringSettingsRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: _hover ? const Color(0xFF1F2A38) : const Color(0xFF18222F),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0xFF22303F)),
          ),
          child: Row(
            children: <Widget>[
              Icon(widget.iconData, size: 14, color: const Color(0xFF7FA6CC)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.label,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12,
                    color: Color(0xFFE6EDF3),
                  ),
                ),
              ),
              if (widget.category != null && widget.category!.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F1822),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: const Color(0xFF22303F)),
                  ),
                  child: Text(
                    widget.category!,
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 9,
                      color: Color(0xFF7FA6CC),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
