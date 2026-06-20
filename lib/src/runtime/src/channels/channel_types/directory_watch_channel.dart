/// Directory watch channel for MCP UI DSL v1.1
///
/// Watches a directory for file changes.
library directory_watch_channel;

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:watcher/watcher.dart';

import '../channel_manager.dart';

/// Channel that watches a directory for changes
class DirectoryWatchChannel implements Channel {
  final String path;
  final bool recursive;

  StreamController<DirectoryWatchEvent>? _controller;
  DirectoryWatcher? _watcher;
  StreamSubscription? _subscription;
  bool _isActive = false;

  DirectoryWatchChannel({
    required this.path,
    this.recursive = false,
  });

  @override
  Future<void> start() async {
    if (kIsWeb) {
      throw UnsupportedError('Directory watching not supported on web');
    }

    if (_isActive) return;

    final dir = Directory(path);
    if (!await dir.exists()) {
      throw FileSystemException('Directory not found', path);
    }

    _controller = StreamController<DirectoryWatchEvent>.broadcast();
    _watcher = DirectoryWatcher(path);

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
