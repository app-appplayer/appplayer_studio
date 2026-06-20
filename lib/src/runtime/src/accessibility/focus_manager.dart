import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import '../utils/mcp_logger.dart';

/// Focus manager for accessibility improvements
/// according to MCP UI DSL v1.0 specification
class MCPFocusManager {
  static MCPFocusManager? _instance;
  static MCPFocusManager get instance => _instance ??= MCPFocusManager._();

  MCPFocusManager._();

  final Map<String, FocusNode> _focusNodes = {};
  final List<String> _traversalOrder = [];
  final Map<String, FocusGroup> _focusGroups = {};
  final MCPLogger _logger = MCPLogger('MCPFocusManager');

  /// Register a focus node
  void registerFocusNode(
    String id,
    FocusNode node, {
    int? order,
    String? groupId,
    String? label,
  }) {
    _focusNodes[id] = node;

    // Set semantic label if provided
    if (label != null) {
      node.onKeyEvent = (node, event) {
        // Announce label when focused
        if (event is KeyDownEvent && node.hasFocus) {
          SemanticsService.announce(label, TextDirection.ltr);
        }
        return KeyEventResult.ignored;
      };
    }

    // Add to traversal order
    if (order != null && order < _traversalOrder.length) {
      _traversalOrder.insert(order, id);
    } else {
      _traversalOrder.add(id);
    }

    // Add to group if specified
    if (groupId != null) {
      _focusGroups.putIfAbsent(groupId, () => FocusGroup(groupId));
      _focusGroups[groupId]!.addNode(id, node);
    }

    _logger.debug('Registered focus node: $id');
  }

  /// Unregister a focus node
  void unregisterFocusNode(String id) {
    final node = _focusNodes.remove(id);
    if (node != null) {
      node.dispose();
    }

    _traversalOrder.remove(id);

    // Remove from all groups
    for (final group in _focusGroups.values) {
      group.removeNode(id);
    }

    _logger.debug('Unregistered focus node: $id');
  }

  /// Get a focus node by ID
  FocusNode? getFocusNode(String id) => _focusNodes[id];

  /// Focus a specific node
  void focus(String id) {
    final node = _focusNodes[id];
    if (node != null) {
      node.requestFocus();
      _logger.debug('Focused node: $id');
    }
  }

  /// Focus the next element in traversal order
  void focusNext() {
    final currentFocus = FocusManager.instance.primaryFocus;
    if (currentFocus == null) {
      // Focus first element
      if (_traversalOrder.isNotEmpty) {
        focus(_traversalOrder.first);
      }
      return;
    }

    // Find current focused element
    String? currentId;
    for (final entry in _focusNodes.entries) {
      if (entry.value == currentFocus) {
        currentId = entry.key;
        break;
      }
    }

    if (currentId != null) {
      final currentIndex = _traversalOrder.indexOf(currentId);
      if (currentIndex >= 0 && currentIndex < _traversalOrder.length - 1) {
        focus(_traversalOrder[currentIndex + 1]);
      } else if (currentIndex == _traversalOrder.length - 1) {
        // Wrap to beginning
        focus(_traversalOrder.first);
      }
    }
  }

  /// Focus the previous element in traversal order
  void focusPrevious() {
    final currentFocus = FocusManager.instance.primaryFocus;
    if (currentFocus == null) {
      // Focus last element
      if (_traversalOrder.isNotEmpty) {
        focus(_traversalOrder.last);
      }
      return;
    }

    // Find current focused element
    String? currentId;
    for (final entry in _focusNodes.entries) {
      if (entry.value == currentFocus) {
        currentId = entry.key;
        break;
      }
    }

    if (currentId != null) {
      final currentIndex = _traversalOrder.indexOf(currentId);
      if (currentIndex > 0) {
        focus(_traversalOrder[currentIndex - 1]);
      } else if (currentIndex == 0) {
        // Wrap to end
        focus(_traversalOrder.last);
      }
    }
  }

  /// Focus first element in a group
  void focusGroup(String groupId) {
    final group = _focusGroups[groupId];
    if (group != null && group.nodeIds.isNotEmpty) {
      focus(group.nodeIds.first);
    }
  }

  /// Trap focus within a group
  void trapFocus(String groupId) {
    final group = _focusGroups[groupId];
    if (group == null) return;

    group.trapFocus = true;
    _logger.debug('Trapped focus in group: $groupId');
  }

  /// Release focus trap
  void releaseFocusTrap(String groupId) {
    final group = _focusGroups[groupId];
    if (group != null) {
      group.trapFocus = false;
      _logger.debug('Released focus trap in group: $groupId');
    }
  }

  /// Clear all focus nodes
  void clear() {
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    _focusNodes.clear();
    _traversalOrder.clear();
    _focusGroups.clear();
  }

  /// Create a focus scope for a widget
  Widget createFocusScope({
    required String scopeId,
    required Widget child,
    bool autofocus = false,
    bool canRequestFocus = true,
  }) {
    return FocusScope(
      autofocus: autofocus,
      canRequestFocus: canRequestFocus,
      child: Builder(
        builder: (context) {
          final scopeNode = FocusScope.of(context);
          registerFocusNode(scopeId, scopeNode);
          return child;
        },
      ),
    );
  }
}

/// Focus group for managing related focus nodes
class FocusGroup {
  final String id;
  final List<String> nodeIds = [];
  final Map<String, FocusNode> nodes = {};
  bool trapFocus = false;

  FocusGroup(this.id);

  void addNode(String nodeId, FocusNode node) {
    nodeIds.add(nodeId);
    nodes[nodeId] = node;
  }

  void removeNode(String nodeId) {
    nodeIds.remove(nodeId);
    nodes.remove(nodeId);
  }
}

/// Focus traversal policy for custom navigation
class MCPFocusTraversalPolicy extends FocusTraversalPolicy {
  final List<String> traversalOrder;
  final Map<String, FocusNode> focusNodes;

  const MCPFocusTraversalPolicy({
    required this.traversalOrder,
    required this.focusNodes,
  });

  @override
  FocusNode findFirstFocus(FocusNode currentNode,
      {bool ignoreCurrentFocus = false}) {
    if (traversalOrder.isEmpty) return currentNode;
    return focusNodes[traversalOrder.first] ?? currentNode;
  }

  @override
  FocusNode findLastFocus(FocusNode currentNode,
      {bool ignoreCurrentFocus = false}) {
    if (traversalOrder.isEmpty) return currentNode;
    return focusNodes[traversalOrder.last] ?? currentNode;
  }

  @override
  FocusNode? findFirstFocusInDirection(
      FocusNode currentNode, TraversalDirection direction) {
    switch (direction) {
      case TraversalDirection.up:
      case TraversalDirection.left:
        return findFirstFocus(currentNode);
      case TraversalDirection.down:
      case TraversalDirection.right:
        return findLastFocus(currentNode);
    }
  }

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    switch (direction) {
      case TraversalDirection.up:
      case TraversalDirection.left:
        return _focusPrevious(currentNode);
      case TraversalDirection.down:
      case TraversalDirection.right:
        return _focusNext(currentNode);
    }
  }

  bool _focusNext(FocusNode currentNode) {
    String? currentId;
    for (final entry in focusNodes.entries) {
      if (entry.value == currentNode) {
        currentId = entry.key;
        break;
      }
    }

    if (currentId != null) {
      final currentIndex = traversalOrder.indexOf(currentId);
      if (currentIndex >= 0 && currentIndex < traversalOrder.length - 1) {
        final nextNode = focusNodes[traversalOrder[currentIndex + 1]];
        nextNode?.requestFocus();
        return true;
      }
    }
    return false;
  }

  bool _focusPrevious(FocusNode currentNode) {
    String? currentId;
    for (final entry in focusNodes.entries) {
      if (entry.value == currentNode) {
        currentId = entry.key;
        break;
      }
    }

    if (currentId != null) {
      final currentIndex = traversalOrder.indexOf(currentId);
      if (currentIndex > 0) {
        final prevNode = focusNodes[traversalOrder[currentIndex - 1]];
        prevNode?.requestFocus();
        return true;
      }
    }
    return false;
  }

  @override
  Iterable<FocusNode> sortDescendants(
      Iterable<FocusNode> descendants, FocusNode currentNode) {
    final sorted = <FocusNode>[];

    for (final id in traversalOrder) {
      final node = focusNodes[id];
      if (node != null && descendants.contains(node)) {
        sorted.add(node);
      }
    }

    // Add any remaining nodes not in traversal order
    for (final node in descendants) {
      if (!sorted.contains(node)) {
        sorted.add(node);
      }
    }

    return sorted;
  }
}

/// Focus restore widget for preserving focus state
class FocusRestore extends StatefulWidget {
  final Widget child;
  final String? focusId;

  const FocusRestore({
    super.key,
    required this.child,
    this.focusId,
  });

  @override
  State<FocusRestore> createState() => _FocusRestoreState();
}

class _FocusRestoreState extends State<FocusRestore> {
  FocusNode? _previousFocus;

  @override
  void initState() {
    super.initState();
    _previousFocus = FocusManager.instance.primaryFocus;
  }

  @override
  void dispose() {
    // Restore focus when widget is disposed
    if (_previousFocus != null && _previousFocus!.canRequestFocus) {
      _previousFocus!.requestFocus();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

/// Minimum touch target sizes per WCAG 2.5.8
class TouchTargetSize {
  static const double minimumSize = 48.0;
  TouchTargetSize._();
}

/// Skip to content widget for accessibility
class SkipToContent extends StatelessWidget {
  final String label;
  final VoidCallback onSkip;

  const SkipToContent({
    super.key,
    this.label = 'Skip to main content',
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: GestureDetector(
        onTap: onSkip,
        child: Container(
          padding: const EdgeInsets.all(8),
          color: Colors.transparent,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 1, // Visually hidden but accessible
              color: Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }
}
