/// Channel binding resolver for MCP UI DSL v1.1
///
/// Resolves {{channels.*}} bindings to channel data values.
/// Integrates with ChannelManager to retrieve data from active channels.
library channel_binding_resolver;

import '../channels/channel_manager.dart';
import '../utils/mcp_logger.dart';

/// Resolves channel-related binding expressions
class ChannelBindingResolver {
  final MCPLogger _logger = MCPLogger('ChannelBindingResolver');

  /// Channel manager for accessing channel data
  ChannelManager? _channelManager;

  /// Cached latest data per channel (updated via stream listeners)
  final Map<String, dynamic> _latestData = {};

  /// Set the channel manager and start listening for data
  void setChannelManager(ChannelManager channelManager) {
    _channelManager = channelManager;
  }

  /// Update cached data for a channel (called when channel emits data)
  void updateChannelData(String channelId, dynamic data) {
    _latestData[channelId] = data;
  }

  /// Check if a binding expression is a channels binding
  bool isChannelBinding(String expression) {
    return expression.startsWith('{{channels.') && expression.endsWith('}}');
  }

  /// Extract the channel path from an expression
  String? extractPath(String expression) {
    if (!isChannelBinding(expression)) return null;
    return expression.substring(11, expression.length - 2);
  }

  /// Resolve a channels binding expression
  ///
  /// Supported patterns:
  /// - `channels.{channelId}` -> latest data from channel
  /// - `channels.{channelId}.{dataKey}` -> specific field from channel data
  /// - `channels.{channelId}.active` -> whether channel is active
  dynamic resolve(String expression) {
    final path = extractPath(expression);
    if (path == null) return null;

    return _resolveChannel(path);
  }

  /// Resolve a channel path
  dynamic _resolveChannel(String path) {
    final parts = path.split('.');
    if (parts.isEmpty) return null;

    final channelId = parts[0];

    // Check if channel exists
    if (_channelManager != null && !_channelManager!.hasChannel(channelId)) {
      _logger.warning('Channel not found: $channelId');
      return null;
    }

    // If only channel ID, return the latest data
    if (parts.length == 1) {
      return _latestData[channelId];
    }

    final dataKey = parts[1];

    // Special property: check if channel is active
    if (dataKey == 'active') {
      return _channelManager?.hasChannel(channelId) ?? false;
    }

    // Special property: get channel state as string
    if (dataKey == 'state') {
      return _channelManager?.getChannelState(channelId).name ?? 'disconnected';
    }

    // Get specific field from latest channel data
    final data = _latestData[channelId];
    if (data == null) return null;

    // Navigate the remaining path through the data
    dynamic current = data;
    for (int i = 1; i < parts.length; i++) {
      if (current is Map<String, dynamic>) {
        current = current[parts[i]];
      } else {
        return null;
      }
    }

    return current;
  }

  /// Clear cached data for a channel
  void clearChannelData(String channelId) {
    _latestData.remove(channelId);
  }

  /// Clear all cached data
  void clearAll() {
    _latestData.clear();
  }
}
