/// File watch channel for MCP UI DSL v1.1
///
/// Watches a single file for changes.
library file_watch_channel;

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:watcher/watcher.dart';

import '../channel_manager.dart';

/// Channel that watches a file for changes
class FileWatchChannel implements Channel {
  final String path;

  StreamController<FileWatchEvent>? _controller;
  FileWatcher? _watcher;
  StreamSubscription? _subscription;
  bool _isActive = false;

  FileWatchChannel({required this.path});

  @override
  Future<void> start() async {
    if (kIsWeb) {
      throw UnsupportedError('File watching not supported on web');
    }

    if (_isActive) return;

    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('File not found', path);
    }

    _controller = StreamController<FileWatchEvent>.broadcast();
    _watcher = FileWatcher(path);

    _subscription = _watcher!.events.listen(
      (event) {
        _controller?.add(FileWatchEvent(
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
  FileWatchEventType _mapEventType(ChangeType type) {
    return switch (type) {
      ChangeType.ADD => FileWatchEventType.created,
      ChangeType.MODIFY => FileWatchEventType.modified,
      ChangeType.REMOVE => FileWatchEventType.deleted,
      _ => FileWatchEventType.modified,
    };
  }
}

/// Event emitted when a file changes
class FileWatchEvent {
  final FileWatchEventType type;
  final String path;
  final DateTime timestamp;

  FileWatchEvent({
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
  String toString() => 'FileWatchEvent($type, $path)';
}

/// Types of file watch events
enum FileWatchEventType {
  created,
  modified,
  deleted,
}
