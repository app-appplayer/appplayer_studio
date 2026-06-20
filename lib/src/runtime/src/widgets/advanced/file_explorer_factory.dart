/// File explorer widget factory for MCP UI DSL v1.1
///
/// Provides a file/folder tree explorer view.
library file_explorer_factory;

import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for File Explorer widgets
class FileExplorerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final items = context.resolve<List<dynamic>>(properties['items'])
            as List<dynamic>? ??
        [];
    final showIcons = properties['showIcons'] as bool? ?? true;
    final showHidden = properties['showHidden'] as bool? ?? false;
    final expandAll = properties['expandAll'] as bool? ?? false;
    final width = (properties['width'] as num?)?.toDouble();
    final height = (properties['height'] as num?)?.toDouble();

    // Theme colors
    final backgroundColor = parseColor(properties['backgroundColor'], context);
    final selectedColor = parseColor(properties['selectedColor'], context) ??
        (context.themeManager
            .getColorValue('primary')
            ?.withValues(alpha: 0.2)) ??
        Colors.blue.withValues(alpha: 0.2);
    final iconColor = parseColor(properties['iconColor'], context);

    // Action handlers
    final onSelect = (properties['onSelect'] ?? properties['select']) as Map<String, dynamic>?;
    final onOpen = (properties['onOpen'] ?? properties['open']) as Map<String, dynamic>?;

    Widget explorer = _FileExplorer(
      items: _parseItems(items),
      showIcons: showIcons,
      showHidden: showHidden,
      expandAll: expandAll,
      backgroundColor: backgroundColor,
      selectedColor: selectedColor,
      iconColor: iconColor,
      onSelect: onSelect,
      onOpen: onOpen,
      context: context,
    );

    if (width != null || height != null) {
      explorer = SizedBox(
        width: width,
        height: height,
        child: explorer,
      );
    }

    return applyCommonWrappers(explorer, properties, context);
  }

  List<FileItem> _parseItems(List<dynamic> items) {
    return items.map((item) {
      if (item is Map<String, dynamic>) {
        return FileItem.fromJson(item);
      }
      return FileItem(name: item.toString(), type: FileItemType.file);
    }).toList();
  }
}

class _FileExplorer extends StatefulWidget {
  final List<FileItem> items;
  final bool showIcons;
  final bool showHidden;
  final bool expandAll;
  final Color? backgroundColor;
  final Color selectedColor;
  final Color? iconColor;
  final Map<String, dynamic>? onSelect;
  final Map<String, dynamic>? onOpen;
  final RenderContext context;

  const _FileExplorer({
    required this.items,
    required this.showIcons,
    required this.showHidden,
    required this.expandAll,
    this.backgroundColor,
    required this.selectedColor,
    this.iconColor,
    this.onSelect,
    this.onOpen,
    required this.context,
  });

  @override
  State<_FileExplorer> createState() => _FileExplorerState();
}

class _FileExplorerState extends State<_FileExplorer> {
  String? _selectedPath;
  final Set<String> _expandedPaths = {};

  @override
  void initState() {
    super.initState();
    if (widget.expandAll) {
      _expandAllFolders(widget.items, '');
    }
  }

  void _expandAllFolders(List<FileItem> items, String basePath) {
    for (final item in items) {
      if (item.type == FileItemType.folder) {
        final path = basePath.isEmpty ? item.name : '$basePath/${item.name}';
        _expandedPaths.add(path);
        if (item.children != null) {
          _expandAllFolders(item.children!, path);
        }
      }
    }
  }

  void _toggleExpand(String path) {
    setState(() {
      if (_expandedPaths.contains(path)) {
        _expandedPaths.remove(path);
      } else {
        _expandedPaths.add(path);
      }
    });
  }

  void _selectItem(FileItem item, String path) {
    setState(() {
      _selectedPath = path;
    });

    if (widget.onSelect != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'name': item.name,
            'path': path,
            'type': item.type.name,
          }
        },
      );
      widget.context.actionHandler.execute(widget.onSelect!, eventContext);
    }
  }

  void _openItem(FileItem item, String path) {
    if (widget.onOpen != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'name': item.name,
            'path': path,
            'type': item.type.name,
          }
        },
      );
      widget.context.actionHandler.execute(widget.onOpen!, eventContext);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleItems = widget.showHidden
        ? widget.items
        : widget.items.where((i) => !i.name.startsWith('.')).toList();

    return Container(
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView(
        children: _buildItems(visibleItems, '', 0),
      ),
    );
  }

  List<Widget> _buildItems(List<FileItem> items, String basePath, int depth) {
    final widgets = <Widget>[];

    // Sort: folders first, then files, alphabetically
    final sorted = List<FileItem>.from(items);
    sorted.sort((a, b) {
      if (a.type == FileItemType.folder && b.type != FileItemType.folder) {
        return -1;
      }
      if (a.type != FileItemType.folder && b.type == FileItemType.folder) {
        return 1;
      }
      return a.name.compareTo(b.name);
    });

    for (final item in sorted) {
      if (!widget.showHidden && item.name.startsWith('.')) continue;

      final path = basePath.isEmpty ? item.name : '$basePath/${item.name}';
      final isExpanded = _expandedPaths.contains(path);
      final isSelected = _selectedPath == path;

      widgets.add(_buildItem(item, path, depth, isExpanded, isSelected));

      // Add children if expanded folder
      if (item.type == FileItemType.folder &&
          isExpanded &&
          item.children != null) {
        widgets.addAll(_buildItems(item.children!, path, depth + 1));
      }
    }

    return widgets;
  }

  Widget _buildItem(
    FileItem item,
    String path,
    int depth,
    bool isExpanded,
    bool isSelected,
  ) {
    final isFolder = item.type == FileItemType.folder;

    return InkWell(
      onTap: () {
        if (isFolder) {
          _toggleExpand(path);
        }
        _selectItem(item, path);
      },
      onDoubleTap: () => _openItem(item, path),
      child: Container(
        padding: EdgeInsets.only(
          left: 8.0 + (depth * 16.0),
          right: 8.0,
          top: 6.0,
          bottom: 6.0,
        ),
        decoration: BoxDecoration(
          color: isSelected ? widget.selectedColor : null,
        ),
        child: Row(
          children: [
            // Expand/collapse icon for folders
            if (isFolder)
              Icon(
                isExpanded
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_right,
                size: 16,
                color: widget.iconColor,
              )
            else
              const SizedBox(width: 16),

            // File/folder icon
            if (widget.showIcons) ...[
              const SizedBox(width: 4),
              Icon(
                _getIcon(item),
                size: 16,
                color: widget.iconColor ?? _getIconColor(item),
              ),
              const SizedBox(width: 8),
            ],

            // Name
            Expanded(
              child: Text(
                item.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isFolder ? FontWeight.w500 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getIcon(FileItem item) {
    switch (item.type) {
      case FileItemType.folder:
        return Icons.folder;
      case FileItemType.file:
        return _getFileIcon(item.name);
    }
  }

  IconData _getFileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'dart':
        return Icons.code;
      case 'js':
      case 'ts':
      case 'jsx':
      case 'tsx':
        return Icons.javascript;
      case 'json':
        return Icons.data_object;
      case 'md':
        return Icons.description;
      case 'yaml':
      case 'yml':
        return Icons.settings;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'svg':
        return Icons.image;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getIconColor(FileItem item) {
    switch (item.type) {
      case FileItemType.folder:
        return Colors.amber;
      case FileItemType.file:
        return Colors.blueGrey;
    }
  }
}

/// File/folder item
class FileItem {
  final String name;
  final FileItemType type;
  final String? path;
  final List<FileItem>? children;

  FileItem({
    required this.name,
    required this.type,
    this.path,
    this.children,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'file';
    final type =
        typeStr == 'folder' ? FileItemType.folder : FileItemType.file;

    List<FileItem>? children;
    if (json['children'] is List) {
      children = (json['children'] as List)
          .map((c) => FileItem.fromJson(c as Map<String, dynamic>))
          .toList();
    }

    return FileItem(
      name: json['name'] as String? ?? '',
      type: type,
      path: json['path'] as String?,
      children: children,
    );
  }
}

/// Type of file item
enum FileItemType {
  file,
  folder,
}
