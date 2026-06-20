/// Channel message protocol model for MCP UI DSL v1.1
///
/// Provides structured message representation with id, direction,
/// sequence, and timestamp per spec §2160-2187.
library channel_message;

/// Direction of a channel message
enum ChannelMessageDirection {
  /// Message from client to server
  clientToServer,

  /// Message from server to client
  serverToClient,
}

/// Type of channel message
enum ChannelMessageType {
  /// Regular data message
  message,

  /// Control/system message
  control,

  /// Error message
  error,
}

/// Structured channel message with protocol metadata
class ChannelMessage {
  /// Unique message identifier
  final String id;

  /// Channel this message belongs to
  final String channel;

  /// Message direction
  final ChannelMessageDirection direction;

  /// Message type
  final ChannelMessageType type;

  /// Message payload data
  final dynamic payload;

  /// Timestamp when the message was created
  final DateTime timestamp;

  /// Optional sequence number for ordering
  final int? sequence;

  const ChannelMessage({
    required this.id,
    required this.channel,
    required this.direction,
    this.type = ChannelMessageType.message,
    required this.payload,
    required this.timestamp,
    this.sequence,
  });

  /// Create an inbound (server-to-client) message
  factory ChannelMessage.inbound(
    String channel,
    dynamic payload, {
    int? sequence,
    ChannelMessageType type = ChannelMessageType.message,
  }) {
    return ChannelMessage(
      id: _generateId(),
      channel: channel,
      direction: ChannelMessageDirection.serverToClient,
      type: type,
      payload: payload,
      timestamp: DateTime.now(),
      sequence: sequence,
    );
  }

  /// Create an outbound (client-to-server) message
  factory ChannelMessage.outbound(
    String channel,
    dynamic payload, {
    int? sequence,
    ChannelMessageType type = ChannelMessageType.message,
  }) {
    return ChannelMessage(
      id: _generateId(),
      channel: channel,
      direction: ChannelMessageDirection.clientToServer,
      type: type,
      payload: payload,
      timestamp: DateTime.now(),
      sequence: sequence,
    );
  }

  /// Create from JSON
  factory ChannelMessage.fromJson(Map<String, dynamic> json) {
    return ChannelMessage(
      id: json['id'] as String? ?? _generateId(),
      channel: json['channel'] as String? ?? '',
      direction: json['direction'] == 'clientToServer'
          ? ChannelMessageDirection.clientToServer
          : ChannelMessageDirection.serverToClient,
      type: _parseType(json['type'] as String?),
      payload: json['payload'],
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
      sequence: json['sequence'] as int?,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'channel': channel,
      'direction': direction == ChannelMessageDirection.clientToServer
          ? 'clientToServer'
          : 'serverToClient',
      'type': type.name,
      'payload': payload,
      'timestamp': timestamp.toIso8601String(),
      if (sequence != null) 'sequence': sequence,
    };
  }

  static ChannelMessageType _parseType(String? type) {
    switch (type) {
      case 'control':
        return ChannelMessageType.control;
      case 'error':
        return ChannelMessageType.error;
      case 'message':
      default:
        return ChannelMessageType.message;
    }
  }

  /// Simple ID generator using timestamp + counter
  static int _idCounter = 0;
  static String _generateId() {
    _idCounter++;
    return 'msg_${DateTime.now().microsecondsSinceEpoch}_$_idCounter';
  }

  @override
  String toString() =>
      'ChannelMessage($id, $channel, ${direction.name}, seq=$sequence)';
}
