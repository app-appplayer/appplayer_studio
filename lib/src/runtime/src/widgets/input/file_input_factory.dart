import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../assets/asset_ref.dart';
import '../../assets/asset_resolver.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `fileInput` (spec §2.6.24).
///
/// Core, and the reason is a boundary rather than a feature. Reading a path
/// the *document* names reaches into the host's filesystem and belongs behind
/// a `file.read` grant. Receiving a file the *user chose in a picker* is the
/// opposite act — the choosing is the consent, and the app learns nothing it
/// was not handed. Same trust level as `signature`, which already takes
/// user-drawn input.
///
/// The selection lands in state as `[{name, size, mimeType, bytes?, path?}]`.
/// `bytes` is a `data:` URI, hence a valid `AssetRef`, so a picked image
/// renders with no upload round-trip.
class FileInputFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final binding = properties['binding'] as String?;
    final enabled = context.resolve<bool?>(properties['enabled']) ?? true;
    final label = context.resolve<String?>(properties['label']);
    final multiple = context.resolve<bool?>(properties['multiple']) ?? false;
    final preview = context.resolve<bool?>(properties['preview']) ?? false;
    final maxBytes = context.resolve<num?>(properties['maxBytes'])?.toInt();
    final maxFiles = context.resolve<num?>(properties['maxFiles'])?.toInt();
    final accept =
        (context.resolve<List<dynamic>?>(properties['accept']) ?? const [])
            .map((e) => e.toString())
            .toList();
    final onChange = properties['onChange'] as Map<String, dynamic>?;
    final onError = properties['onError'] as Map<String, dynamic>?;

    final selected =
        binding != null && context.getState(binding) is List
            ? List<dynamic>.from(context.getState(binding) as List)
            : const <dynamic>[];

    void emit(Map<String, dynamic>? action, Map<String, dynamic> event) {
      if (action == null) return;
      context.actionHandler.execute(
        action,
        context.createChildContext(variables: {'event': event}),
      );
    }

    Future<void> pick() async {
      try {
        final extensions = _extensionsFrom(accept);
        final result = await FilePicker.platform.pickFiles(
          allowMultiple: multiple,
          withData: true, // web has no path; bytes are the portable answer
          type: extensions.isEmpty ? FileType.any : FileType.custom,
          allowedExtensions: extensions.isEmpty ? null : extensions,
        );
        if (result == null || result.files.isEmpty) {
          // Cancel is an empty selection, not an error.
          if (binding != null) context.setValue(binding, const []);
          return;
        }

        var files = result.files;
        if (maxFiles != null && files.length > maxFiles) {
          files = files.take(maxFiles).toList();
        }

        final descriptors = <Map<String, dynamic>>[];
        for (final f in files) {
          if (maxBytes != null && f.size > maxBytes) {
            // Oversized files surface rather than vanishing (spec §2.6.24).
            emit(onError, {
              'type': 'error',
              'code': 'maxBytes',
              'name': f.name,
              'size': f.size,
              'message': '${f.name} exceeds $maxBytes bytes',
            });
            continue;
          }
          final mime = _mimeFor(f.extension);
          descriptors.add({
            'name': f.name,
            'size': f.size,
            'mimeType': mime,
            if (f.bytes != null)
              'bytes': 'data:$mime;base64,${base64Encode(f.bytes!)}',
            // Absent on web, and that absence is part of the contract.
            if (f.path != null) 'path': f.path,
          });
        }

        if (binding != null) context.setValue(binding, descriptors);
        emit(onChange, {'type': 'change', 'value': descriptors});
      } catch (e) {
        emit(onError, {
          'type': 'error',
          'code': 'picker',
          'message': e.toString(),
        });
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton.icon(
          onPressed: enabled ? pick : null,
          icon: const Icon(Icons.attach_file),
          label: Text(label ?? 'Choose file'),
        ),
        if (selected.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final f in selected)
            if (f is Map)
              _SelectedFile(
                name: f['name']?.toString() ?? '',
                size: (f['size'] as num?)?.toInt(),
                dataUri: preview ? f['bytes']?.toString() : null,
              ),
        ],
      ],
    );
  }

  /// Maps MIME patterns and dotted extensions onto the picker's extension
  /// filter. A pattern like `image/*` has no extension list, so it widens to
  /// "any" rather than silently excluding everything.
  static List<String> _extensionsFrom(List<String> accept) {
    final out = <String>[];
    for (final a in accept) {
      if (a.startsWith('.')) out.add(a.substring(1));
    }
    return out;
  }

  static String _mimeFor(String? extension) {
    switch (extension?.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'svg':
        return 'image/svg+xml';
      case 'pdf':
        return 'application/pdf';
      case 'csv':
        return 'text/csv';
      case 'json':
        return 'application/json';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }
}

class _SelectedFile extends StatelessWidget {
  const _SelectedFile({required this.name, this.size, this.dataUri});

  final String name;
  final int? size;
  final String? dataUri;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dataUri != null && dataUri!.startsWith('data:image')) ...[
            SizedBox(
              width: 40,
              height: 40,
              // Through the one asset path (§6.12) — a data: URI is a valid
              // AssetRef, and Image.network would not decode it on any
              // platform.
              child: Builder(builder: (_) {
                final provider = AssetResolver.builtin
                    .imageProviderFor(AssetRef.parse(dataUri)!);
                return provider == null
                    ? const SizedBox.shrink()
                    : Image(image: provider, fit: BoxFit.cover);
              }),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
          if (size != null) ...[
            const SizedBox(width: 8),
            Text('$size B', style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
