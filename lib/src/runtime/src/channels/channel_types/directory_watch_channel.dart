/// Directory watch channel for MCP UI DSL v1.1
///
/// Watches a directory for file changes.
library directory_watch_channel;

import 'dart:async';
import '../../platform/host_platform.dart';
import 'dart:io';
import 'package:watcher/watcher.dart';

import '../channel_manager.dart';

/// Channel that watches a directory for changes
class DirectoryWatchChannel implements Channel {
  final String path;
  final bool recursive;

  StreamController<DirectoryWatchEvent>? _controller;
  Watcher? _watcher;
  StreamSubscription? _subscription;
  bool _isActive = false;

  DirectoryWatchChannel({
    required this.path,
    this.recursive = false,
  });

  /// How the channel obtains its watcher.
  ///
  /// See [FileWatchChannel.watcherFactory] — the reasoning is the same, and a
  /// directory adds one more shape a real filesystem will not produce on
  /// demand: a rename, which arrives as a removal and an addition.
  static Watcher Function(String path) watcherFactory = DirectoryWatcher.new;

  @override
  Future<void> start() async {
    if (HostPlatform.isWeb) {
      throw UnsupportedError('Directory watching not supported on web');
    }

    if (_isActive) return;

    final dir = Directory(path);
    if (!await dir.exists()) {
      throw FileSystemException('Directory not found', path);
    }

    _controller = StreamController<DirectoryWatchEvent>.broadcast();
    _watcher = watcherFactory(path);

    _subscription = _watcher!.events.listen(
      (event) {
        _controller?.add(DirectoryWatchEvent(
          type: _mapEventType(event.type),
          path: event.path,
          timestamp: DateTime.now(),
        ));
      },
      onError: (error) {
        _controller?.addError(error);
      },
    );

    await _watcher!.ready;
    _isActive = true;
  }

  @override
  Future<void> stop() async {
    _isActive = false;
    await _subscription?.cancel();
    _subscription = null;
    await _controller?.close();
    _controller = null;
    _watcher = null;
  }

  @override
  Stream<dynamic> get stream =>
      _controller?.stream ?? const Stream.empty();

  @override
  bool get isActive => _isActive;

  /// Map watcher event type to our event type
  DirectoryWatchEventType _mapEventType(ChangeType type) {
    return switch (type) {
      ChangeType.ADD => DirectoryWatchEventType.created,
      ChangeType.MODIFY => DirectoryWatchEventType.modified,
      ChangeType.REMOVE => DirectoryWatchEventType.deleted,
      _ => DirectoryWatchEventType.modified,
    };
  }
}

/// Event emitted when a directory changes
class DirectoryWatchEvent {
  final DirectoryWatchEventType type;
  final String path;
  final DateTime timestamp;

  DirectoryWatchEvent({
    required this.type,
    required this.path,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'path': path,
        'timestamp': timestamp.toIso8601String(),
      };

  @override
  String toString() => 'DirectoryWatchEvent($type, $path)';
}

/// Types of directory watch events
enum DirectoryWatchEventType {
  created,
  modified,
  deleted,
}
