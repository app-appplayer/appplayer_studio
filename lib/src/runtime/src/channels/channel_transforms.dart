/// Channel data transforms for MCP UI DSL v1.1
///
/// Supports filter, map, debounce, throttle, distinct, window, buffer transforms.
library channel_transforms;

import 'dart:async';

/// Provides stream transformation operators for channel data
class ChannelTransforms {
  /// Apply a filter transform - only passes events matching a condition
  ///
  /// The [predicate] function receives each event and should return true
  /// to pass the event through, or false to drop it.
  static Stream<dynamic> filter(
    Stream<dynamic> source,
    dynamic Function(dynamic) predicate,
  ) {
    return source.where((event) {
      final result = predicate(event);
      if (result is bool) return result;
      // Truthy evaluation for non-bool results
      return result != null && result != false && result != 0 && result != '';
    });
  }

  /// Apply a map transform - transforms each event
  ///
  /// The [mapper] function receives each event and returns the transformed value.
  static Stream<dynamic> mapTransform(
    Stream<dynamic> source,
    dynamic Function(dynamic) mapper,
  ) {
    return source.map(mapper);
  }

  /// Apply debounce - only emit after silence period
  ///
  /// Delays emission of events and only emits the latest value after
  /// [duration] has passed without any new events arriving.
  static Stream<dynamic> debounce(
    Stream<dynamic> source,
    Duration duration,
  ) {
    late StreamController<dynamic> controller;
    StreamSubscription<dynamic>? subscription;
    Timer? debounceTimer;

    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        subscription = source.listen(
          (data) {
            debounceTimer?.cancel();
            debounceTimer = Timer(duration, () {
              if (!controller.isClosed) {
                controller.add(data);
              }
            });
          },
          onError: (error, stackTrace) {
            controller.addError(error, stackTrace);
          },
          onDone: () {
            debounceTimer?.cancel();
            controller.close();
          },
        );
      },
      onCancel: () {
        debounceTimer?.cancel();
        subscription?.cancel();
      },
    );

    return controller.stream;
  }

  /// Apply throttle - limit emission rate
  ///
  /// Emits the first event and then ignores subsequent events for [duration].
  /// After the duration passes, the next event will be emitted.
  static Stream<dynamic> throttle(
    Stream<dynamic> source,
    Duration duration,
  ) {
    late StreamController<dynamic> controller;
    StreamSubscription<dynamic>? subscription;
    bool throttled = false;
    Timer? throttleTimer;

    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        subscription = source.listen(
          (data) {
            if (!throttled) {
              throttled = true;
              controller.add(data);
              throttleTimer = Timer(duration, () {
                throttled = false;
              });
            }
          },
          onError: (error, stackTrace) {
            controller.addError(error, stackTrace);
          },
          onDone: () {
            throttleTimer?.cancel();
            controller.close();
          },
        );
      },
      onCancel: () {
        throttleTimer?.cancel();
        subscription?.cancel();
      },
    );

    return controller.stream;
  }

  /// Apply distinct - only emit when value changes
  ///
  /// Filters out consecutive duplicate values. An optional [equals] function
  /// can be provided for custom equality comparison.
  static Stream<dynamic> distinct(
    Stream<dynamic> source, {
    bool Function(dynamic, dynamic)? equals,
  }) {
    if (equals != null) {
      late StreamController<dynamic> controller;
      StreamSubscription<dynamic>? subscription;
      dynamic lastValue;
      bool hasLastValue = false;

      controller = StreamController<dynamic>.broadcast(
        onListen: () {
          subscription = source.listen(
            (data) {
              if (!hasLastValue || !equals(lastValue, data)) {
                hasLastValue = true;
                lastValue = data;
                controller.add(data);
              }
            },
            onError: (error, stackTrace) {
              controller.addError(error, stackTrace);
            },
            onDone: () {
              controller.close();
            },
          );
        },
        onCancel: () {
          subscription?.cancel();
        },
      );

      return controller.stream;
    }

    return source.distinct();
  }

  /// Apply window - batch events into lists by time window
  ///
  /// Collects events during each [duration] window and emits them as a list
  /// when the window closes. Empty windows emit an empty list.
  static Stream<List<dynamic>> window(
    Stream<dynamic> source,
    Duration duration,
  ) {
    late StreamController<List<dynamic>> controller;
    StreamSubscription<dynamic>? subscription;
    Timer? windowTimer;
    List<dynamic> currentWindow = [];

    controller = StreamController<List<dynamic>>.broadcast(
      onListen: () {
        void emitWindow() {
          final batch = List<dynamic>.from(currentWindow);
          currentWindow = [];
          if (!controller.isClosed) {
            controller.add(batch);
          }
        }

        windowTimer = Timer.periodic(duration, (_) {
          emitWindow();
        });

        subscription = source.listen(
          (data) {
            currentWindow.add(data);
          },
          onError: (error, stackTrace) {
            controller.addError(error, stackTrace);
          },
          onDone: () {
            windowTimer?.cancel();
            // Emit remaining events
            if (currentWindow.isNotEmpty) {
              controller.add(List<dynamic>.from(currentWindow));
              currentWindow = [];
            }
            controller.close();
          },
        );
      },
      onCancel: () {
        windowTimer?.cancel();
        subscription?.cancel();
      },
    );

    return controller.stream;
  }

  /// Apply buffer - accumulate events to specified count
  ///
  /// Collects events until [count] events have been received, then emits
  /// them as a list. Remaining events are emitted when the source completes.
  static Stream<List<dynamic>> buffer(
    Stream<dynamic> source,
    int count,
  ) {
    if (count <= 0) {
      throw ArgumentError.value(count, 'count', 'Must be greater than zero');
    }

    late StreamController<List<dynamic>> controller;
    StreamSubscription<dynamic>? subscription;
    List<dynamic> currentBuffer = [];

    controller = StreamController<List<dynamic>>.broadcast(
      onListen: () {
        subscription = source.listen(
          (data) {
            currentBuffer.add(data);
            if (currentBuffer.length >= count) {
              final batch = List<dynamic>.from(currentBuffer);
              currentBuffer = [];
              controller.add(batch);
            }
          },
          onError: (error, stackTrace) {
            controller.addError(error, stackTrace);
          },
          onDone: () {
            // Emit remaining buffered events
            if (currentBuffer.isNotEmpty) {
              controller.add(List<dynamic>.from(currentBuffer));
              currentBuffer = [];
            }
            controller.close();
          },
        );
      },
      onCancel: () {
        subscription?.cancel();
      },
    );

    return controller.stream;
  }
}
